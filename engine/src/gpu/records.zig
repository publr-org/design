//! The GPU canvas's records: a page walked once and written as flat lists the GPU keeps,
//! in each top-level node's own units rather than device pixels (`docs/gpu.md`, "Records").
//!
//! Every shape, paint and clip is in its node's space and names the node's matrix to its
//! top-level node (the transform table). A frame only says where each top-level node is:
//! its camera, the matrix `Session.place` gives it at the frame's scale and its whole-pixel
//! offset (`frame`). The shaders compose the two, so pixels are numbered as on the CPU (top
//! space) and panning and zooming touch nothing here.
//!
//! Paths and glyphs are kept as their curves (node space; glyphs in font units, once per
//! font and glyph, shared by every text). The fragment shader flattens them as the CPU
//! does at the frame's scale and counts crossings at Figma's 16 sample points: coverage
//! is the CPU's at any scale, and nothing is made per scale.

const std = @import("std");
const m = @import("../pubd/model.zig");
const geom = @import("../raster/geom.zig");
const mask_mod = @import("../raster/mask.zig");
const pix = @import("../raster/pixmap.zig");
const render = @import("../render/render.zig");
const session_mod = @import("../session.zig");
const text_layout = @import("../text/layout.zig");
const font_mod = @import("../text/font.zig");
const efx = @import("../render/effects.zig");
const colour = @import("../render/colour.zig");
const scene_mod = @import("scene.zig");

const Affine = geom.Affine;
const Path = geom.Path;
const Vec2 = geom.Vec2;
const Rect = geom.Rect;
const Session = session_mod.Session;
const Allocator = std.mem.Allocator;
const Paint = scene_mod.Paint;
const PaintKind = scene_mod.PaintKind;
const Feature = scene_mod.Feature;
const Op = scene_mod.Op;

pub const none = scene_mod.none;

/// The records' binary layout version (`docs/gpu.md`); bumped when a record changes.
pub const layout_version: u32 = 1;

/// The WGSL the host compiles for records (with the shared paint code first).
pub const shader = @embedFile("common.wgsl") ++ @embedFile("curves.wgsl") ++ @embedFile("records.wgsl");

/// One quad: its pixels get the paint, times the coverage of its shape (and of `shape2`,
/// kept or cut out), its clip chain and its opacity.
pub const Prim = extern struct {
    /// Where it may paint, in its top-level node's units (the quad covers this mapped to
    /// device pixels, `margin` device pixels more).
    x0: f32,
    y0: f32,
    x1: f32,
    y1: f32,
    shape: u32,
    shape2: u32,
    clip: u32,
    paint: u32,
    op: u32,
    /// The node's matrix (the transform table).
    xf: u32,
    /// Its top-level node.
    top: u32,
    feature: u32,
    opacity: f32,
    /// Bits 0..7: how it composites (`scene.Blend`).
    blend: u32 = 0,
    /// The item whose stand-in this prim is (its node drawn plainly while the item has no
    /// pixels): hidden when that item, or one around it, has pixels (`none`: none).
    owner: u32 = none,
    /// Device pixels the quad reaches past `x0..y1` mapped (a blur's fixed reach).
    margin: f32 = 1,
};

pub const ShapeKind = enum(u32) {
    rect = 1,
    ellipse = 2,
    /// A path's curves (`paths`), node space.
    path = 3,
    /// A glyph's curves (font units) through its glyph matrix.
    glyph = 4,
};

/// A shape in its node's space. Rectangles and ellipses: `v0` the box, `v1` its corner
/// radii, `v2` and `v3` the hole of a ring. Paths: `v0[0]` the path (u32 bits). Glyphs:
/// `v0` the path (u32 bits) and the glyph matrix's a, b, c; `v1` its d, e, f.
pub const Shape = extern struct {
    kind: u32,
    /// The next clip of a chain (`none`: the last).
    next: u32,
    /// The node's matrix.
    xf: u32,
    /// Bit 0: `v2` is a hole (the ring). Bit 1: even-odd (paths).
    flags: u32,
    v0: [4]f32 = .{ 0, 0, 0, 0 },
    v1: [4]f32 = .{ 0, 0, 0, 0 },
    v2: [4]f32 = .{ 0, 0, 0, 0 },
    v3: [4]f32 = .{ 0, 0, 0, 0 },
    v4: [4]f32 = .{ 0, 0, 0, 0 },
    v5: [4]f32 = .{ 0, 0, 0, 0 },
    v6: [4]f32 = .{ 0, 0, 0, 0 },
};

/// A path's curves, with the horizontal bands that list which curves reach each.
pub const PathRec = extern struct {
    curve_first: u32,
    curve_count: u32,
    band_first: u32,
    band_count: u32,
    /// The curves' control points span y0..y1 (the path's units); band k covers
    /// y0 + k * (y1 - y0) / band_count onward.
    y0: f32,
    y1: f32,
    /// Its coverage mask (`masks`; `none`: none).
    mask: u32 = none,
    pad: u32 = 0,
};

/// Paths of this many curves or more get a coverage mask: drawn small, a pixel reads the
/// mask rather than every curve its rows reach (a dense pattern of tiny shapes).
pub const mask_curves: u32 = 1000;
/// The longest side of a mask, in texels.
pub const mask_size: u32 = 2048;
/// Masks a page keeps at most (each about 5.6 MB with its levels); paths past them are
/// drawn from their curves.
pub const max_masks: u32 = 16;

/// A path's coverage over its bounds, drawn once on the GPU by the curve shader (16
/// samples a texel) into a layer of the mask texture, with mip levels: where a device
/// pixel spans a texel or more, coverage is the mask's (an area average) instead of the
/// curves'. Paths with the same curves share one.
pub const Mask = extern struct {
    /// The path it is drawn from (its curves at texel = (p - (x0, y0)) * k).
    path: u32,
    /// Its layer of the mask texture.
    layer: u32,
    /// Texels used (from the layer's top left).
    w: u32,
    h: u32,
    x0: f32,
    y0: f32,
    /// Texels per unit of the path.
    k: f32,
    /// Bit 0: even-odd.
    flags: u32,
};

/// An item: a node (or part of one) the CPU draws through layers of its own, drawn by the
/// immediate builder (`scene.zig`, which mirrors the CPU's effects) into a cached picture
/// at a frame's exact matrix, and composited by a prim of paint kind `item`. While it has
/// no picture at this matrix, one of another matrix stands in, or its plain prims (those
/// it owns).
pub const Item = extern struct {
    kind: u32,
    top: u32,
    xf: u32,
    /// The item around it (`none`: none): its pictures include this one's.
    parent: u32,
    /// Where it may paint, top-level units.
    x0: f32,
    y0: f32,
    x1: f32,
    y1: f32,
    /// What its pictures are kept by across builds: the node, the part and the node's
    /// subtree revision (an edit under it makes a new key).
    key_lo: u32,
    key_hi: u32,
    /// The prim compositing it.
    prim: u32 = 0,
    pad1: u32 = 0,

    pub const node: u32 = 1;
    /// The node's drop shadows only (its content is plain prims).
    pub const shadows: u32 = 2;
    /// The node's inner shadows only.
    pub const inner: u32 = 3;
    /// A mask and the siblings it masks (`node` the parent, `child` the mask).
    pub const mask_run: u32 = 4;
    /// What lies under the node, blurred (its background blur): taken from the frame's
    /// target where the composite is drawn, composited through the node's shape.
    pub const backdrop: u32 = 5;
    /// A node that blends with what lies under it (a blend mode): drawn by the immediate
    /// builder straight onto the frame's target where it stands, every frame.
    pub const inframe: u32 = 6;
};

/// Paint kind of an item's composite: `a` the item.
pub const paint_item: u32 = 10;

/// A curve: a cubic's four points, or a line (p1 and p2 NaN) from p0 to p3.
pub const Curve = [8]f32;

/// A band: its curves at `band_items[first .. first + count]` (curve indices).
pub const Band = [2]u32;

/// A run of draws: prims `first .. first + count` with the texture they read.
pub const Draw = extern struct {
    kind: u32,
    first: u32,
    count: u32,
    /// The image the prims' paints read (`none`: none).
    tex: u32,
    flags: u32 = 0,
    top: u32,
    pad0: u32 = 0,
    pad1: u32 = 0,

    pub const prims: u32 = 0;
};

/// A top-level node: its draws, its prims and where it may paint (page units).
pub const Top = extern struct {
    draw_first: u32,
    draw_count: u32,
    prim_first: u32,
    prim_count: u32,
    x0: f32,
    y0: f32,
    x1: f32,
    y1: f32,
};

/// A frame's camera for one top-level node: its matrix to top space and the whole-pixel
/// offset of top space in the target (`Session.place`).
pub const Camera = extern struct {
    a: f32,
    b: f32,
    c: f32,
    d: f32,
    e: f32,
    f: f32,
    ox: i32,
    oy: i32,
};

/// An image the paints read: its asset and size (level 0 of the full chain).
pub const Image = extern struct {
    hash_ptr: u32,
    hash_len: u32,
    width: u32,
    height: u32,
    pad0: u32 = 0,
    pad1: u32 = 0,
    pad2: u32 = 0,
    pad3: u32 = 0,
};

/// What an image's texture holds now (the host writes one per image).
pub const Held = extern struct {
    /// Level 0 of the chain held (the image's first level, or a coarser one).
    w: f32,
    h: f32,
    /// Levels held.
    levels: u32,
    /// Bit 0: a texture is bound.
    ready: u32,
};

pub const Header = extern struct {
    version: u32 = layout_version,
    prims: u32 = 0,
    prim_count: u32 = 0,
    shapes: u32 = 0,
    shape_count: u32 = 0,
    paints: u32 = 0,
    paint_count: u32 = 0,
    stops: u32 = 0,
    stop_count: u32 = 0,
    xforms: u32 = 0,
    xform_count: u32 = 0,
    curves: u32 = 0,
    curve_count: u32 = 0,
    paths: u32 = 0,
    path_count: u32 = 0,
    bands: u32 = 0,
    band_count: u32 = 0,
    band_items: u32 = 0,
    band_item_count: u32 = 0,
    draws: u32 = 0,
    draw_count: u32 = 0,
    tops: u32 = 0,
    top_count: u32 = 0,
    images: u32 = 0,
    image_count: u32 = 0,
    masks: u32 = 0,
    mask_count: u32 = 0,
    items: u32 = 0,
    item_count: u32 = 0,
    /// 1: written whole; 0: top-level nodes added at the ends; 2: nothing changed; 3:
    /// written whole but the paths (their curves, bands and masks) and the images, which
    /// are kept as they were with any new ones at the ends; 4: colours alone changed, the
    /// paints, stops and items' keys painted again in place (nothing added).
    full: u32 = 1,
    /// Nodes walked, glyphs placed.
    nodes: u32 = 0,
    glyphs: u32 = 0,
    /// Nodes drawn without what they need a surface for (effects, group opacity, masks),
    /// until surfaces come (step B).
    approximated: u32 = 0,
    /// Prims per `Feature`.
    features: [12]u32 = @splat(0),
};

/// Per frame: the cameras and which top-level nodes are in view.
pub const FrameHeader = extern struct {
    cameras: u32 = 0,
    camera_count: u32 = 0,
    /// Indices of the top-level nodes in view, in draw order.
    visible: u32 = 0,
    visible_count: u32 = 0,
    /// Items in view (`VisibleItem`).
    items: u32 = 0,
    item_count: u32 = 0,
};

/// What `buildItem` drew: the item's rect (top space) and its matrix.
pub const VisibleItem = extern struct {
    item: u32,
    /// Its device rect in the target.
    x0: i32,
    y0: i32,
    x1: i32,
    y1: i32,
    /// Its matrix now (node to top space).
    ctm: [6]f32,
    pad: u32 = 0,
};

pub const ItemOut = extern struct {
    x0: i32 = 0,
    y0: i32 = 0,
    x1: i32 = 0,
    y1: i32 = 0,
    ctm: [6]f32 = .{ 0, 0, 0, 0, 0, 0 },
    /// The scene's header.
    scene: u32 = 0,
    /// 1: the rect is cut to the view (the item is too large to draw whole).
    cut: u32 = 0,
};

const GlyphKey = struct {
    font: usize,
    glyph: u16,
};

const PathKey = struct {
    node: usize,
    /// 0 the fill, 1 + i region i, `stroke_part` the stroke.
    part: u32,
};

const stroke_part: u32 = 1 << 20;

/// A text node kept between builds: its layout (glyphs point at fonts it holds).
const TextCache = struct {
    /// The node's shape revision it was made at (an edit of its shape makes it stale).
    rev: u32 = 0,
    lay: text_layout.Layout,
    /// The source's own glyphs as paths (the layout is not drawn then), per paint set.
    file: []render.TextPath = &.{},
    /// Each of `file`'s path records (a node written again reads them, as a NodePath's).
    file_recs: []PathAt = &.{},
};

/// Where a kept path is written in the lists (`rec` none: not written in those of `gen`).
const PathAt = struct {
    rec: u32 = none,
    gen: u32 = 0,
};

/// A node's path in node space, parsed once.
const NodePath = struct {
    /// The node's shape revision it was made at.
    rev: u32 = 0,
    /// Its path record.
    at: PathAt = .{},
    path: Path,
    winding: mask_mod.Winding,
    /// Stroke outlines: how the fill cuts them.
    op: render.StrokeGeometry.Op = .none,
};

const ItemNode = struct {
    node: *const m.Node,
    child: u32 = 0,
    /// The node's matrix to its top-level node (its key's).
    mt: [6]f32 = .{ 1, 0, 0, 1, 0, 0 },
};

/// Where a paint record's paint is in its node (to paint it again in place when only
/// colours changed): `list` 0 none (not a node's paint), 1 fills, 2 strokes, 3 the fills
/// of run `at`, 4 the fills of region `at`; `index` in that list.
const PaintSrc = struct {
    node: ?*const m.Node = null,
    top: u32 = 0,
    list: u8 = 0,
    at: u32 = 0,
    index: u32 = 0,
};

const ImageSrc = struct {
    paint: *const m.Paint,
    size: Vec2,
};

/// An image prim the frame asks the feed for, when it is in view.
const ImageUse = struct {
    top: u32,
    xf: u32,
    paint: *const m.Paint,
    size: Vec2,
    /// Where it paints, top-level units.
    rect: Rect,
};

pub const Records = struct {
    gpa: Allocator,
    prims: std.ArrayList(Prim) = .empty,
    shapes: std.ArrayList(Shape) = .empty,
    paints: std.ArrayList(Paint) = .empty,
    /// Each paint record's source (as `paints`).
    paint_srcs: std.ArrayList(PaintSrc) = .empty,
    stops: std.ArrayList([4]f32) = .empty,
    xforms: std.ArrayList([8]f32) = .empty,
    curves: std.ArrayList(Curve) = .empty,
    paths: std.ArrayList(PathRec) = .empty,
    bands: std.ArrayList(Band) = .empty,
    band_items: std.ArrayList(u32) = .empty,
    draws: std.ArrayList(Draw) = .empty,
    tops: std.ArrayList(Top) = .empty,
    top_nodes: std.ArrayList(*const m.Node) = .empty,
    images: std.ArrayList(Image) = .empty,
    image_hashes: std.ArrayList([]const u8) = .empty,
    image_of: std.StringHashMapUnmanaged(u32) = .empty,
    image_uses: std.ArrayList(ImageUse) = .empty,
    glyph_paths: std.AutoHashMapUnmanaged(GlyphKey, u32) = .empty,
    texts: std.AutoHashMapUnmanaged(usize, TextCache) = .empty,
    node_paths: std.AutoHashMapUnmanaged(PathKey, NodePath) = .empty,
    outlines: font_mod.OutlineCache = .{},
    header: Header = .{},
    built_page: ?usize = null,
    /// The page being written a few top-level nodes at a time (`begin`, `step`), and how
    /// many of its top-level nodes are written.
    writing: ?usize = null,
    written: usize = 0,

    // A frame.
    cameras: std.ArrayList(Camera) = .empty,
    visible: std.ArrayList(u32) = .empty,
    frame_header: FrameHeader = .{},

    // The walk.
    sess: *Session = undefined,
    top: u32 = 0,
    /// Opacity the walk folds into every prim (a group drawn without its surface).
    alpha: f32 = 1,
    /// The clip chain's bounds, top-level units (empty: unclipped).
    clip_box: Rect = .empty,
    scratch: Path = .{},
    polys: geom.Polylines = .{},
    /// The top-level node being walked.
    top_nodes_current: ?*const m.Node = null,
    /// Each top-level node's subtree revision when its records were written.
    top_revs: std.ArrayList(u32) = .empty,
    built_kids: ?[*]const m.Node = null,
    /// Where the walked top-level node's draws start.
    draws_from: usize = 0,
    /// Bumped by every whole build (path records of earlier lists are gone).
    gen: u32 = 0,
    /// Path records the last whole build wrote (the rest came with edits since).
    paths_built: usize = 0,
    built_kid_count: usize = 0,
    /// Image paints' sources, by paint record (for the frame's image requests).
    image_srcs: std.AutoHashMapUnmanaged(u32, ImageSrc) = .empty,
    masks: std.ArrayList(Mask) = .empty,
    items: std.ArrayList(Item) = .empty,
    /// Each item's node and (mask runs) child.
    item_nodes: std.ArrayList(ItemNode) = .empty,
    visible_items: std.ArrayList(VisibleItem) = .empty,
    item_out: ItemOut = .{},
    /// The item whose stand-in prims the walk is writing (`none`: none).
    owner: u32 = none,
    mask_of: std.AutoHashMapUnmanaged(u64, u32) = .empty,

    pub fn init(gpa: Allocator) Records {
        return .{
            .gpa = gpa,
        };
    }

    pub fn deinit(self: *Records) void {
        self.forget();
        self.prims.deinit(self.gpa);
        self.shapes.deinit(self.gpa);
        self.paints.deinit(self.gpa);
        self.paint_srcs.deinit(self.gpa);
        self.stops.deinit(self.gpa);
        self.xforms.deinit(self.gpa);
        self.curves.deinit(self.gpa);
        self.paths.deinit(self.gpa);
        self.bands.deinit(self.gpa);
        self.band_items.deinit(self.gpa);
        self.draws.deinit(self.gpa);
        self.tops.deinit(self.gpa);
        self.top_nodes.deinit(self.gpa);
        self.top_revs.deinit(self.gpa);
        self.images.deinit(self.gpa);
        self.image_hashes.deinit(self.gpa);
        self.image_of.deinit(self.gpa);
        self.image_uses.deinit(self.gpa);
        self.image_srcs.deinit(self.gpa);
        self.masks.deinit(self.gpa);
        self.items.deinit(self.gpa);
        self.item_nodes.deinit(self.gpa);
        self.visible_items.deinit(self.gpa);
        self.mask_of.deinit(self.gpa);
        self.glyph_paths.deinit(self.gpa);
        self.texts.deinit(self.gpa);
        self.node_paths.deinit(self.gpa);
        self.outlines.deinit(self.gpa);
        self.cameras.deinit(self.gpa);
        self.visible.deinit(self.gpa);
        self.scratch.deinit(self.gpa);
        self.polys.deinit(self.gpa);
    }

    /// Drops what is kept between builds (the document or its fonts changed).
    pub fn forget(self: *Records) void {
        var ti = self.texts.valueIterator();
        while (ti.next()) |tc| freeText(self.gpa, tc);
        self.texts.clearRetainingCapacity();
        var pi = self.node_paths.valueIterator();
        while (pi.next()) |np| np.path.deinit(self.gpa);
        self.node_paths.clearRetainingCapacity();
        self.outlines.clear(self.gpa);
        self.built_page = null;
        self.writing = null;
    }

    /// Writes the records of page `page_index`.
    pub fn build(self: *Records, sess: *Session, page_index: usize) !void {
        try self.begin(sess, page_index);
        while (try self.step(sess, std.math.maxInt(u32))) {}
    }

    /// Starts writing the records of page `page_index` a few top-level nodes at a time
    /// (`step`), so no one call takes long; the header is written when the last is.
    pub fn begin(self: *Records, sess: *Session, page_index: usize) !void {
        self.sess = sess;
        self.gen +%= 1;
        const pages = sess.pages();
        if (page_index >= pages.len) return error.NoSuchPage;
        self.prims.clearRetainingCapacity();
        self.shapes.clearRetainingCapacity();
        self.paints.clearRetainingCapacity();
        self.paint_srcs.clearRetainingCapacity();
        self.stops.clearRetainingCapacity();
        self.xforms.clearRetainingCapacity();
        self.curves.clearRetainingCapacity();
        self.paths.clearRetainingCapacity();
        self.bands.clearRetainingCapacity();
        self.band_items.clearRetainingCapacity();
        self.draws.clearRetainingCapacity();
        self.tops.clearRetainingCapacity();
        self.top_nodes.clearRetainingCapacity();
        self.images.clearRetainingCapacity();
        self.image_hashes.clearRetainingCapacity();
        self.image_of.clearRetainingCapacity();
        self.image_uses.clearRetainingCapacity();
        self.image_srcs.clearRetainingCapacity();
        self.masks.clearRetainingCapacity();
        self.items.clearRetainingCapacity();
        self.item_nodes.clearRetainingCapacity();
        self.mask_of.clearRetainingCapacity();
        self.glyph_paths.clearRetainingCapacity();
        self.top_revs.clearRetainingCapacity();
        self.header = .{};
        const kids = pages[page_index].children;
        try self.tops.resize(self.gpa, kids.len);
        try self.top_revs.resize(self.gpa, kids.len);
        for (kids) |*c| try self.top_nodes.append(self.gpa, c);
        self.built_page = null;
        self.writing = page_index;
        self.written = 0;
        self.built_kids = kids.ptr;
        self.built_kid_count = kids.len;
    }

    /// Writes up to `count` more top-level nodes of the page `begin` started; false once
    /// the page is written (its header then says where everything is). A page whose list
    /// of top-level nodes changed meanwhile starts again.
    pub fn step(self: *Records, sess: *Session, count: u32) !bool {
        const page_index = self.writing orelse return error.NotWriting;
        self.sess = sess;
        const pages = sess.pages();
        if (page_index >= pages.len) return error.NoSuchPage;
        const kids = pages[page_index].children;
        if (kids.ptr != self.built_kids or kids.len != self.built_kid_count) {
            try self.begin(sess, page_index);
            return true;
        }
        var n: u32 = 0;
        while (self.written < kids.len and n < count) : (n += 1) {
            try self.walkTop(@intCast(self.written));
            self.written += 1;
        }
        if (self.written < kids.len) return true;
        self.writing = null;
        self.built_page = page_index;
        self.paths_built = self.paths.items.len;
        self.header.full = 1;
        self.finish();
        return false;
    }

    /// Top-level node `ti`'s records written at the ends of the lists (its old ones are
    /// left where they are, unread).
    fn walkTop(self: *Records, ti: u32) !void {
        const c = self.top_nodes.items[ti];
        self.top = ti;
        const draw_first: u32 = @intCast(self.draws.items.len);
        const prim_first: u32 = @intCast(self.prims.items.len);
        // Its draws start here: none merges into an earlier node's (or its own old ones).
        self.draws_from = draw_first;
        self.alpha = 1;
        self.owner = none;
        self.clip_box = .empty;
        self.top_nodes_current = c;
        try self.node(c, Affine.identity, none);
        const b = render.cullBounds(c, c.transform);
        self.tops.items[ti] = .{
            .draw_first = draw_first,
            .draw_count = @as(u32, @intCast(self.draws.items.len)) - draw_first,
            .prim_first = prim_first,
            .prim_count = @as(u32, @intCast(self.prims.items.len)) - prim_first,
            .x0 = b.x0,
            .y0 = b.y0,
            .x1 = b.x1,
            .y1 = b.y1,
        };
        self.top_revs.items[ti] = c.tree_rev;
    }

    /// Top-level node `ti` written again (an edit changed something in it).
    pub fn rebuildTop(self: *Records, sess: *Session, ti: u32) !void {
        self.sess = sess;
        // Its items and image uses go; what is new comes at the ends.
        for (self.items.items) |*it| {
            if (it.top == ti) it.top = none;
        }
        var keep: usize = 0;
        for (self.image_uses.items) |u| {
            if (u.top != ti) {
                self.image_uses.items[keep] = u;
                keep += 1;
            }
        }
        self.image_uses.shrinkRetainingCapacity(keep);
        try self.walkTop(ti);
    }

    /// Brings the records of page `page_index` up to date: nothing when nothing changed,
    /// the top-level nodes an edit changed written again, everything but the paths (more
    /// than half of the lists unread), or everything (another page, a new list of
    /// top-level nodes, or as many paths again as the page was built with). `header.full`
    /// says which (2: none changed, 1: written whole, 0: added at the ends, 3: written
    /// whole but the paths, 4: colours alone changed, painted again in place).
    pub fn update(self: *Records, sess: *Session, page_index: usize) !void {
        const pages = sess.pages();
        if (page_index >= pages.len) return error.NoSuchPage;
        const kids = pages[page_index].children;
        if (self.built_page != page_index or kids.ptr != self.built_kids or kids.len != self.built_kid_count) return self.build(sess, page_index);
        self.sess = sess;
        // Top-level nodes changed in colours alone are painted again in place, when all
        // that changed are (a colour picker's drag); the rest are written again.
        var changed = false;
        var all_recolour = true;
        for (self.top_nodes.items, 0..) |c, ti| {
            if (c.tree_rev == self.top_revs.items[ti]) continue;
            changed = true;
            if (!unchangedSince(c, self.top_revs.items[ti])) all_recolour = false;
        }
        if (!changed) {
            self.header.full = 2;
            return;
        }
        if (all_recolour and self.recolour()) {
            for (self.top_nodes.items, 0..) |c, ti| self.top_revs.items[ti] = c.tree_rev;
            self.header.full = 4;
            return;
        }
        for (self.top_nodes.items, 0..) |c, ti| {
            if (c.tree_rev == self.top_revs.items[ti]) continue;
            try self.rebuildTop(sess, @intCast(ti));
        }
        var live: usize = 0;
        for (self.tops.items) |t| live += t.prim_count;
        if (self.prims.items.len > 2 * live + 4096) {
            if (self.paths.items.len > 2 * self.paths_built + 1024) return self.build(sess, page_index);
            return self.compact(sess);
        }
        self.header.full = 0;
        self.finish();
    }

    /// The paint records (and stops) of the top-level nodes that changed painted again
    /// from their nodes, and the keys of their items made again (their pictures hold the
    /// old colours); false, with nothing changed, when one no longer fits its record.
    fn recolour(self: *Records) bool {
        for (self.paint_srcs.items, self.paints.items) |src, p| {
            const n = src.node orelse continue;
            if (n.tree_rev <= self.top_revs.items[src.top]) continue;
            const paint = paintAt(n, src) orelse return false;
            if (!fits(paint, p)) return false;
        }
        for (self.paint_srcs.items, self.paints.items) |src, *p| {
            const n = src.node orelse continue;
            if (n.tree_rev <= self.top_revs.items[src.top]) continue;
            const paint = paintAt(n, src).?;
            if (paint.kind == .image) continue;
            p.* = (self.paintOut(paint, n.size, .{
                .stops_at = if (p.b > 0) p.a else null,
            }) catch return false).?;
        }
        for (self.items.items, self.item_nodes.items) |*it, in| {
            if (it.top == none) continue;
            if (self.top_nodes.items[it.top].tree_rev == self.top_revs.items[it.top]) continue;
            const key = itemKey(in.node, it.kind, in.child, in.mt);
            it.key_lo = @truncate(key);
            it.key_hi = @truncate(key >> 32);
        }
        return true;
    }

    /// Every top-level node written again into emptied lists, the paths and the images
    /// kept: a page whose every node an edit changes (a colour all of it uses) writes its
    /// paints again, not the curves of its text.
    fn compact(self: *Records, sess: *Session) !void {
        self.sess = sess;
        self.prims.clearRetainingCapacity();
        self.shapes.clearRetainingCapacity();
        self.paints.clearRetainingCapacity();
        self.paint_srcs.clearRetainingCapacity();
        self.stops.clearRetainingCapacity();
        self.xforms.clearRetainingCapacity();
        self.draws.clearRetainingCapacity();
        self.image_uses.clearRetainingCapacity();
        self.image_srcs.clearRetainingCapacity();
        self.items.clearRetainingCapacity();
        self.item_nodes.clearRetainingCapacity();
        self.header = .{};
        for (0..self.top_nodes.items.len) |ti| try self.walkTop(@intCast(ti));
        self.header.full = 3;
        self.finish();
    }

    fn finish(self: *Records) void {
        const h = &self.header;
        h.prims = addr(self.prims.items.ptr);
        h.prim_count = @intCast(self.prims.items.len);
        h.shapes = addr(self.shapes.items.ptr);
        h.shape_count = @intCast(self.shapes.items.len);
        h.paints = addr(self.paints.items.ptr);
        h.paint_count = @intCast(self.paints.items.len);
        h.stops = addr(self.stops.items.ptr);
        h.stop_count = @intCast(self.stops.items.len);
        h.xforms = addr(self.xforms.items.ptr);
        h.xform_count = @intCast(self.xforms.items.len);
        h.curves = addr(self.curves.items.ptr);
        h.curve_count = @intCast(self.curves.items.len);
        h.paths = addr(self.paths.items.ptr);
        h.path_count = @intCast(self.paths.items.len);
        h.bands = addr(self.bands.items.ptr);
        h.band_count = @intCast(self.bands.items.len);
        h.band_items = addr(self.band_items.items.ptr);
        h.band_item_count = @intCast(self.band_items.items.len);
        h.draws = addr(self.draws.items.ptr);
        h.draw_count = @intCast(self.draws.items.len);
        h.tops = addr(self.tops.items.ptr);
        h.top_count = @intCast(self.tops.items.len);
        h.images = addr(self.images.items.ptr);
        h.image_count = @intCast(self.images.items.len);
        h.masks = addr(self.masks.items.ptr);
        h.mask_count = @intCast(self.masks.items.len);
        h.items = addr(self.items.items.ptr);
        h.item_count = @intCast(self.items.items.len);
    }

    // ------------------------------------------------------------------ frames

    /// The cameras of a frame of `w` x `h` device pixels with world (`x`, `y`) at the top
    /// left and `scale` device pixels per unit, the top-level nodes in view, and the images
    /// in view asked of the session (at the detail the frame draws them).
    pub fn frame(self: *Records, sess: *Session, x: f64, y: f64, scale: f32, w: u32, h: u32) !void {
        self.cameras.clearRetainingCapacity();
        self.visible.clearRetainingCapacity();
        const sd: f64 = scale;
        const vx = @round(x * sd);
        const vy = @round(y * sd);
        const view: Rect = .{
            .x1 = @floatFromInt(w),
            .y1 = @floatFromInt(h),
        };
        sess.beginPass();
        for (self.top_nodes.items, self.tops.items, 0..) |c, t, ti| {
            const at = scene_mod.placeAt(c, vx, vy, scale);
            try self.cameras.append(self.gpa, .{
                .a = at.ctm.a,
                .b = at.ctm.b,
                .c = at.ctm.c,
                .d = at.ctm.d,
                .e = at.ctm.e,
                .f = at.ctm.f,
                .ox = at.dx,
                .oy = at.dy,
            });
            // The node's bounds (page units) on screen.
            const s64: f64 = scale;
            const bx0 = @as(f64, t.x0) * s64 - vx;
            const by0 = @as(f64, t.y0) * s64 - vy;
            const bx1 = @as(f64, t.x1) * s64 - vx;
            const by1 = @as(f64, t.y1) * s64 - vy;
            if (bx1 < 0 or by1 < 0 or bx0 > @as(f64, view.x1) or by0 > @as(f64, view.y1)) continue;
            if (t.prim_count == 0) continue;
            try self.visible.append(self.gpa, @intCast(ti));
        }
        // Images in view, at the detail they draw at.
        for (self.image_uses.items) |u| {
            const cam = self.cameras.items[u.top];
            const ctm_top: Affine = .{
                .a = cam.a,
                .b = cam.b,
                .c = cam.c,
                .d = cam.d,
                .e = cam.e,
                .f = cam.f,
            };
            const r = Rect.transformed(u.rect, ctm_top);
            const ox: f32 = @floatFromInt(cam.ox);
            const oy: f32 = @floatFromInt(cam.oy);
            if (r.x1 + ox < 0 or r.y1 + oy < 0 or r.x0 + ox > view.x1 or r.y0 + oy > view.y1) continue;
            try sess.ensurePaintAt(u.paint, u.size, ctm_top.mul(self.xformAt(u.xf)));
        }
        // Items in view (of nodes in view), with their device rects.
        self.visible_items.clearRetainingCapacity();
        for (self.items.items, 0..) |it, ii| {
            if (it.top == none) continue;
            const cam = self.cameras.items[it.top];
            const ctm_top: Affine = .{
                .a = cam.a,
                .b = cam.b,
                .c = cam.c,
                .d = cam.d,
                .e = cam.e,
                .f = cam.f,
            };
            const r = Rect.transformed(.{
                .x0 = it.x0,
                .y0 = it.y0,
                .x1 = it.x1,
                .y1 = it.y1,
            }, ctm_top);
            const ox: f32 = @floatFromInt(cam.ox);
            const oy: f32 = @floatFromInt(cam.oy);
            if (r.x1 + ox < 0 or r.y1 + oy < 0 or r.x0 + ox > view.x1 or r.y0 + oy > view.y1) continue;
            const ctm = ctm_top.mul(self.xformAt(it.xf));
            try self.visible_items.append(self.gpa, .{
                .item = @intCast(ii),
                .x0 = @intFromFloat(std.math.clamp(@floor(r.x0 + ox), -1e9, 1e9)),
                .y0 = @intFromFloat(std.math.clamp(@floor(r.y0 + oy), -1e9, 1e9)),
                .x1 = @intFromFloat(std.math.clamp(@ceil(r.x1 + ox), -1e9, 1e9)),
                .y1 = @intFromFloat(std.math.clamp(@ceil(r.y1 + oy), -1e9, 1e9)),
                .ctm = .{ ctm.a, ctm.b, ctm.c, ctm.d, ctm.e, ctm.f },
            });
        }
        const fh = &self.frame_header;
        fh.items = addr(self.visible_items.items.ptr);
        fh.item_count = @intCast(self.visible_items.items.len);
        fh.cameras = addr(self.cameras.items.ptr);
        fh.camera_count = @intCast(self.cameras.items.len);
        fh.visible = addr(self.visible.items.ptr);
        fh.visible_count = @intCast(self.visible.items.len);
    }

    /// Item `index` drawn by the immediate builder `sc` at the last frame's camera, over
    /// its whole rect when that is at most `max_px` pixels, else over the frame's view
    /// (`w` x `h`) and `margin` around it; `item_out` says what was drawn.
    pub fn buildItem(self: *Records, sc: *scene_mod.Scene, sess: *Session, index: u32, w: u32, h: u32, margin: i32, max_px: u64) !void {
        const it = self.items.items[index];
        const in = self.item_nodes.items[index];
        const cam = self.cameras.items[it.top];
        const ctm_top: Affine = .{
            .a = cam.a,
            .b = cam.b,
            .c = cam.c,
            .d = cam.d,
            .e = cam.e,
            .f = cam.f,
        };
        const ctm = ctm_top.mul(self.xformAt(it.xf));
        var rect = mask_mod.IRect.around(Rect.transformed(.{
            .x0 = it.x0,
            .y0 = it.y0,
            .x1 = it.x1,
            .y1 = it.y1,
        }, ctm_top));
        var cut = false;
        if (it.kind == Item.backdrop or it.kind == Item.inframe) {
            // The whole target: the blur reads what the frame drew there.
            rect = .{
                .x0 = -cam.ox,
                .y0 = -cam.oy,
                .x1 = -cam.ox + @as(i32, @intCast(w)),
                .y1 = -cam.oy + @as(i32, @intCast(h)),
            };
        } else if (@as(u64, rect.width()) * rect.height() > max_px) {
            cut = true;
            const view: mask_mod.IRect = .{
                .x0 = -cam.ox - margin,
                .y0 = -cam.oy - margin,
                .x1 = -cam.ox + @as(i32, @intCast(w)) + margin,
                .y1 = -cam.oy + @as(i32, @intCast(h)) + margin,
            };
            rect = rect.intersect(view);
        }
        try sc.buildItem(sess, in.node, it.kind, in.child, ctm, rect);
        self.item_out = .{
            .x0 = rect.x0,
            .y0 = rect.y0,
            .x1 = rect.x1,
            .y1 = rect.y1,
            .ctm = .{ ctm.a, ctm.b, ctm.c, ctm.d, ctm.e, ctm.f },
            .scene = addr(&sc.header),
            .cut = @intFromBool(cut),
        };
    }

    fn xformAt(self: *const Records, i: u32) Affine {
        const v = self.xforms.items[i];
        return .{
            .a = v[0],
            .b = v[1],
            .c = v[2],
            .d = v[3],
            .e = v[4],
            .f = v[5],
        };
    }

    /// Image `index`'s chain as held now (null: none yet).
    pub fn held(self: *const Records, sess: *Session, index: u32) ?*const pix.Mipmap {
        if (index >= self.image_hashes.items.len) return null;
        return sess.images.getPtr(self.image_hashes.items[index]);
    }

    // ------------------------------------------------------------------ the walk

    fn pushXform(self: *Records, mt: Affine) !u32 {
        const i: u32 = @intCast(self.xforms.items.len);
        try self.xforms.append(self.gpa, .{ mt.a, mt.b, mt.c, mt.d, mt.e, mt.f, 0, 0 });
        return i;
    }

    /// Mirrors `Renderer.drawNode` (and `Scene.node`), without culling: `mt` is the node's
    /// matrix to its top-level node.
    fn node(self: *Records, n: *const m.Node, mt: Affine, clip: u32) anyerror!void {
        if (!n.visible or n.opacity <= 0 or n.kind == .slice) return;
        if (n.kind == .text and (self.sess.renderer.fonts == null or n.text == null)) return;
        self.header.nodes += 1;
        const xf = try self.pushXform(mt);
        const fx = hasEffects(n);
        const isolate = n.opacity < 1 or fx or (n.blend != .pass_through and n.blend != .normal) or hasPattern(n);
        if (!isolate) return self.content(n, mt, xf, clip, 1);
        if (!fx and (n.blend == .pass_through or n.blend == .normal) and n.children.len == 0 and !scene_mod.paintsBlend(n) and scene_mod.paintCount(n) <= 1) {
            return self.content(n, mt, xf, clip, n.opacity);
        }
        return self.isolated(n, mt, xf, clip);
    }

    /// A node the CPU draws through a layer of its own: an item. When the layer is only
    /// for its shadows (opacity 1, normal blend, no layer effects), the shadows alone are
    /// the item and its content is plain prims; otherwise the whole node is, with its
    /// content as plain prims standing in (the group's opacity on each).
    fn isolated(self: *Records, n: *const m.Node, mt: Affine, xf: u32, clip: u32) !void {
        var whole = n.opacity < 1 or (n.blend != .pass_through and n.blend != .normal) or scene_mod.paintsBlend(n) or hasPattern(n);
        var surface_shadows = false;
        const formula = self.formulaShape(n, mt);
        for (n.effects) |e| {
            if (!e.visible) continue;
            switch (e.kind) {
                .drop_shadow => if (formula == null) {
                    surface_shadows = true;
                },
                .inner_shadow => {},
                .layer_blur, .noise, .texture, .background_blur => whole = true,
            }
        }
        if (!whole) whole = try self.kidsReadBackdrop(n);
        if (!whole) {
            if (surface_shadows) {
                _ = try self.item(Item.shadows, n, 0, mt, xf, clip, render.cullBounds(n, Affine.identity));
            } else for (n.effects) |e| {
                if (e.visible and e.kind == .drop_shadow) try self.formulaShadow(n, e, xf, clip, formula.?);
            }
            return self.content(n, mt, xf, clip, 1);
        }
        // A blend mode reads the frame: drawn onto it in place (inside another item, that
        // item's picture has it).
        const blends = (n.blend != .pass_through and n.blend != .normal) or scene_mod.paintsBlend(n);
        if (blends and self.owner == none) {
            _ = try self.item(Item.inframe, n, 0, mt, xf, clip, render.cullBounds(n, Affine.identity));
            return;
        }
        var blurs = false;
        for (n.effects) |e| {
            if (e.visible and e.kind == .background_blur) blurs = true;
        }
        // A background blur reads the frame (inside another item, that item's picture has it).
        if (blurs and self.owner == none) {
            _ = try self.item(Item.backdrop, n, 0, mt, xf, clip, render.cullBounds(n, Affine.identity));
        } else if (blurs) self.header.approximated += 1;
        const it = try self.item(Item.node, n, 0, mt, xf, clip, render.cullBounds(n, Affine.identity));
        const saved_owner = self.owner;
        const saved = self.alpha;
        self.owner = it;
        self.alpha *= n.opacity;
        defer {
            self.alpha = saved;
            self.owner = saved_owner;
        }
        if (formula) |f| for (n.effects) |e| {
            if (e.visible and e.kind == .drop_shadow) try self.formulaShadow(n, e, xf, clip, f);
        };
        try self.content(n, mt, xf, clip, 1);
    }

    /// Whether a node under `n` reads what lies under it (blend modes, background blurs).
    fn kidsReadBackdrop(self: *Records, n: *const m.Node) !bool {
        _ = self;
        for (n.children) |*c| if (readsBackdrop(c)) return true;
        return false;
    }

    /// An item and the prim compositing it, over `bounds` (node space).
    fn item(self: *Records, kind: u32, n: *const m.Node, child: u32, mt: Affine, xf: u32, clip: u32, bounds: Rect) !u32 {
        const r = Rect.transformed(bounds, mt);
        const i: u32 = @intCast(self.items.items.len);
        const m6: [6]f32 = .{ mt.a, mt.b, mt.c, mt.d, mt.e, mt.f };
        const key = itemKey(n, kind, child, m6);
        try self.items.append(self.gpa, .{
            .key_lo = @truncate(key),
            .key_hi = @truncate(key >> 32),
            .kind = kind,
            .top = self.top,
            .xf = xf,
            .parent = self.owner,
            .x0 = r.x0,
            .y0 = r.y0,
            .x1 = r.x1,
            .y1 = r.y1,
        });
        try self.item_nodes.append(self.gpa, .{
            .node = n,
            .child = child,
            .mt = m6,
        });
        const paint = try self.pushPaint(.{
            .kind = paint_item,
            .flags = 0,
            .a = i,
            .b = 0,
            .color = .{ 0, 0, 0, 0 },
            .inv = .{ 1, 0, 0, 1 },
            .inv_t = .{ 0, 0, 0, 0 },
        }, .{});
        self.items.items[i].prim = @intCast(self.prims.items.len);
        if (kind == Item.backdrop) {
            const fill = try self.fillOf(n, self.xformAt(xf), xf);
            if (fill == none) {
                _ = self.items.pop();
                _ = self.item_nodes.pop();
                return none;
            }
            try self.addPrim(fill, none, .none, clip, paint, 1, .layer, xf, .normal);
        } else try self.emit(bounds, xf, none, none, .none, clip, paint, 1, .layer, .normal, 1);
        return i;
    }

    /// Mirrors `Renderer.drawContent`.
    fn content(self: *Records, n: *const m.Node, mt: Affine, xf: u32, clip: u32, opacity: f32) anyerror!void {
        const fill = try self.fillOf(n, mt, xf);
        const clips = n.clip and n.children.len > 0 and fill != none;

        const regions = render.use_geometry and scene_mod.hasRegionFills(n);
        if (regions) for (n.geometry, 0..) |g, gi| {
            const s = try self.pathShape(n, @intCast(gi + 1), mt, xf);
            if (s == none) continue;
            for (g.fills orelse n.fills) |*p| {
                if (!p.visible or p.kind == .pattern) continue;
                const paint = try self.paintFor(n, p) orelse continue;
                try self.addPrim(s, none, .none, clip, paint, opacity * p.opacity, .fill_path, xf, render.blendMode(p.blend));
            }
        };

        if (!regions and fill != none) for (n.fills) |*p| {
            if (!p.visible or p.kind == .pattern) continue;
            const paint = try self.paintFor(n, p) orelse continue;
            const feature: Feature = if (self.shapes.items[fill].kind == @backingInt(ShapeKind.path)) .fill_path else .fill_formula;
            try self.addPrim(fill, none, .none, clip, paint, opacity * p.opacity, feature, xf, render.blendMode(p.blend));
        };

        if (fill != none) {
            var all_formula = true;
            for (n.effects) |e| {
                if (e.visible and e.kind == .inner_shadow and !self.innerFormula(n, mt, fill)) all_formula = false;
            }
            if (all_formula) {
                for (n.effects) |e| {
                    if (e.visible and e.kind == .inner_shadow) try self.innerShadow(n, e, mt, xf, clip, fill);
                }
            } else _ = try self.item(Item.inner, n, 0, mt, xf, clip, .{
                .x1 = n.size.x,
                .y1 = n.size.y,
            });
        }

        if (n.kind == .text) try self.text(n, mt, xf, clip, opacity);

        if (n.children.len > 0) {
            if (clips) {
                const saved = self.clip_box;
                defer self.clip_box = saved;
                const chain = try self.pushClip(fill, clip, mt);
                try self.children(n, mt, chain);
            } else try self.children(n, mt, clip);
        }

        if (scene_mod.hasVisible(n.strokes) and n.stroke.weight > 0) try self.strokes(n, mt, xf, clip, opacity, fill);
    }

    /// Mirrors `Renderer.drawChildren`. A mask run is clipped by the mask's own shape (a
    /// vector mask exactly; alpha and luminance masks as if opaque, until surfaces come).
    fn children(self: *Records, n: *const m.Node, mt: Affine, clip: u32) anyerror!void {
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
                for (n.children) |*c| try self.node(c, mt.mul(t).mul(c.transform), clip);
            }
            return;
        }
        const kids = n.children;
        if (n.reverse_z) {
            var k = kids.len;
            while (k > 0) {
                k -= 1;
                try self.node(&kids[k], mt.mul(kids[k].transform), clip);
            }
            return;
        }
        var i: usize = 0;
        while (i < kids.len) {
            const c = &kids[i];
            if (c.mask != null) {
                var j = i + 1;
                while (j < kids.len and kids[j].mask == null) j += 1;
                if (c.visible and j > i + 1) {
                    var b: Rect = .empty;
                    for (kids[i + 1 .. j]) |*k| b = b.unite(render.cullBounds(k, k.transform));
                    const pxf = try self.pushXform(mt);
                    const it = try self.item(Item.mask_run, n, @intCast(i), mt, pxf, clip, b);
                    const saved_owner = self.owner;
                    self.owner = it;
                    defer self.owner = saved_owner;
                    // Standing in: the masked siblings clipped by the mask's shape.
                    const cm = mt.mul(c.transform);
                    const cxf = try self.pushXform(cm);
                    const ms = try self.fillOf(c, cm, cxf);
                    const saved = self.clip_box;
                    defer self.clip_box = saved;
                    const chain = if (ms != none) try self.pushClip(ms, clip, cm) else clip;
                    for (kids[i + 1 .. j]) |*k| try self.node(k, mt.mul(k.transform), chain);
                }
                i = j;
            } else {
                try self.node(c, mt.mul(c.transform), clip);
                i += 1;
            }
        }
    }

    /// Mirrors `Renderer.drawText`: each glyph a prim of its own (its curves through its
    /// glyph matrix), decorations as rectangles; the source's own glyphs as paths.
    fn text(self: *Records, n: *const m.Node, mt: Affine, xf: u32, clip: u32, opacity: f32) !void {
        const tc = try self.textOf(n) orelse return;
        if (tc.file.len > 0) {
            for (tc.file, 0..) |*tp, si| {
                const s = try self.pathShapeIn(&tp.path, .nonzero, mt, xf, .{
                    .at = &tc.file_recs[si],
                });
                if (s == none) continue;
                for (runFills(n, tp.run)) |*p| {
                    if (!p.visible) continue;
                    const paint = try self.paintFor(n, p) orelse continue;
                    try self.addPrim(s, none, .none, clip, paint, opacity * p.opacity, .text, xf, .normal);
                }
            }
            return;
        }
        const lay = &tc.lay;
        for (lay.styles.items, 0..) |st, si| {
            const fills = runFills(n, st.fills_run);
            // The style's paints, once for all its glyphs.
            var paints: [8]u32 = undefined;
            var alphas: [8]f32 = undefined;
            var np: usize = 0;
            for (fills) |*p| {
                if (!p.visible or np == paints.len) continue;
                paints[np] = try self.paintFor(n, p) orelse continue;
                alphas[np] = opacity * p.opacity;
                np += 1;
            }
            if (np == 0) continue;
            for (lay.glyphs.items) |g| {
                if (g.style != si) continue;
                const s = try self.glyphShape(g, mt, xf) orelse continue;
                self.header.glyphs += 1;
                for (paints[0..np], alphas[0..np]) |p, a| try self.addPrim(s, none, .none, clip, p, a, .text, xf, .normal);
            }
            for (lay.decorations.items) |d| {
                if (d.style != si) continue;
                const s = try self.boxShape(.rect, d.rect, .{ 0, 0, 0, 0 }, xf, mt, .{});
                for (paints[0..np], alphas[0..np]) |p, a| try self.addPrim(s, none, .none, clip, p, a, .text, xf, .normal);
            }
        }
    }

    /// The paints of run `run` of text node `n` (null: the node's), read from the node:
    /// a kept layout outlives an edit of the paints alone, which gives them new slices.
    fn runFills(n: *const m.Node, run: ?u32) []const m.Paint {
        const ri = run orelse return n.fills;
        const runs = n.text.?.runs;
        if (ri < runs.len) if (runs[ri].fills) |f| return f;
        return n.fills;
    }

    fn textOf(self: *Records, n: *const m.Node) !?*TextCache {
        if (self.texts.getPtr(@intFromPtr(n))) |tc| {
            if (tc.rev == n.shape_rev) return tc;
            freeText(self.gpa, tc);
            _ = self.texts.remove(@intFromPtr(n));
        }
        const r = &self.sess.renderer;
        if (r.usesFileGlyphs(n)) {
            var list: std.ArrayList(render.TextPath) = .empty;
            errdefer {
                for (list.items) |*tp| tp.path.deinit(self.gpa);
                list.deinit(self.gpa);
            }
            try r.fileTextPaths(n, &list);
            const file = try list.toOwnedSlice(self.gpa);
            errdefer {
                for (file) |*tp| tp.path.deinit(self.gpa);
                self.gpa.free(file);
            }
            const recs = try self.gpa.alloc(PathAt, file.len);
            errdefer self.gpa.free(recs);
            @memset(recs, .{});
            try self.texts.put(self.gpa, @intFromPtr(n), .{
                .rev = n.shape_rev,
                .lay = .{},
                .file = file,
                .file_recs = recs,
            });
            return self.texts.getPtr(@intFromPtr(n)).?;
        }
        var lay = try r.textLayout(n) orelse return null;
        errdefer lay.deinit(self.gpa);
        try self.texts.put(self.gpa, @intFromPtr(n), .{
            .rev = n.shape_rev,
            .lay = lay,
        });
        return self.texts.getPtr(@intFromPtr(n)).?;
    }

    /// A glyph's shape: its curves (font units, read once per font and glyph) through its
    /// glyph matrix. Null for a glyph with no outline.
    fn glyphShape(self: *Records, g: text_layout.Placed, mt: Affine, xf: u32) !?u32 {
        const got = try self.glyph_paths.getOrPut(self.gpa, .{
            .font = @intFromPtr(g.font),
            .glyph = g.glyph,
        });
        if (!got.found_existing) {
            self.scratch.verbs.clearRetainingCapacity();
            self.scratch.points.clearRetainingCapacity();
            self.outlines.outline(self.gpa, g.font, g.glyph, Affine.identity, &self.scratch) catch {
                got.value_ptr.* = none;
                return null;
            };
            got.value_ptr.* = if (self.scratch.verbs.items.len == 0) none else try self.addPath(&self.scratch);
        }
        const pi = got.value_ptr.*;
        if (pi == none) return null;
        const pr = self.paths.items[pi];
        if (pr.curve_count == 0) return null;
        const gm = render.glyphTransform(g);
        // The glyph's bounds: its curves' control points through the glyph matrix.
        var fb: Rect = .empty;
        for (self.curves.items[pr.curve_first..][0..pr.curve_count]) |cv| {
            fb.include(.{
                .x = cv[0],
                .y = cv[1],
            });
            fb.include(.{
                .x = cv[6],
                .y = cv[7],
            });
            if (cv[2] == cv[2]) {
                fb.include(.{
                    .x = cv[2],
                    .y = cv[3],
                });
                fb.include(.{
                    .x = cv[4],
                    .y = cv[5],
                });
            }
        }
        const nb = Rect.transformed(fb, gm);
        return try self.pushShape(.{
            .kind = @backingInt(ShapeKind.glyph),
            .next = none,
            .xf = xf,
            .flags = 0,
            .v0 = .{ @bitCast(pi), gm.a, gm.b, gm.c },
            .v1 = .{ gm.d, gm.e, gm.f, 0 },
            // Bounds, node space (for the prim's quad).
            .v6 = .{ nb.x0, nb.y0, nb.x1, nb.y1 },
        }, mt);
    }

    fn strokes(self: *Records, n: *const m.Node, mt: Affine, xf: u32, clip: u32, opacity: f32, fill: u32) !void {
        if (render.strokeIsRing(n)) {
            const d = render.ringInsets(n);
            const o = scene_mod.insetRect(n.size, n.radius, d[0]) orelse return;
            const in = scene_mod.insetRect(n.size, n.radius, d[1]);
            const s = try self.boxShape(.rect, o.rect, o.radii, xf, mt, .{
                .inner = if (in) |i| i.rect else null,
                .inner_radii = if (in) |i| i.radii else .{ 0, 0, 0, 0 },
            });
            for (n.strokes) |*p| {
                if (!p.visible or p.kind == .pattern) continue;
                const paint = try self.paintFor(n, p) orelse continue;
                try self.addPrim(s, none, .none, clip, paint, opacity * p.opacity, .stroke_ring, xf, .normal);
            }
            return;
        }
        const key: PathKey = .{
            .node = @intFromPtr(n),
            .part = stroke_part,
        };
        var got = try self.node_paths.getOrPut(self.gpa, key);
        if (got.found_existing and got.value_ptr.rev != n.shape_rev) {
            got.value_ptr.path.deinit(self.gpa);
            got.found_existing = false;
        }
        if (!got.found_existing) {
            got.value_ptr.* = .{
                .rev = n.shape_rev,
                .path = .{},
                .winding = .nonzero,
            };
            try self.strokePath(n, got.value_ptr);
        }
        const sp = got.value_ptr;
        if (sp.path.verbs.items.len == 0) return;
        const s = try self.pathShapeIn(&sp.path, sp.winding, mt, xf, .{
            .at = &sp.at,
        });
        if (s == none) return;
        // The fill's coverage cuts the stroke where the CPU has a fill mask.
        var op: Op = switch (sp.op) {
            .none => .none,
            .intersect => .intersect,
            .subtract => .subtract,
        };
        if (fill == none) op = .none;
        for (n.strokes) |*p| {
            if (!p.visible or p.kind == .pattern) continue;
            const paint = try self.paintFor(n, p) orelse continue;
            try self.addPrim(s, if (op != .none) fill else none, op, clip, paint, opacity * p.opacity, .stroke_path, xf, .normal);
        }
    }

    /// The stroke's outline in node space: the stored one, or made from the centre line
    /// as `Renderer.strokeDevice` makes it (flattened finely enough for deep zoom).
    fn strokePath(self: *Records, n: *const m.Node, out: *NodePath) !void {
        const al = n.stroke.alignFor(n.kind);
        if (render.use_stroke_outlines and n.stroke.outline.len > 0) {
            var evenodd = false;
            for (n.stroke.outline) |o| {
                geom.parseSvgPath(self.gpa, o.d, &out.path) catch {};
                if (o.winding == .evenodd) evenodd = true;
            }
            out.winding = if (evenodd) .evenodd else .nonzero;
            out.op = render.StrokeGeometry.Op.of(al);
            return;
        }
        // Made here: the device outline at a scale fine enough for deep zoom, mapped back.
        const fine: f32 = 64;
        var shape: Path = .{};
        defer shape.deinit(self.gpa);
        _ = try self.sess.renderer.fillPath(n, &shape);
        self.polys.clear();
        const sg = try self.sess.renderer.strokeDevice(n, &shape, Affine.scaling(fine, fine), &self.polys);
        for (self.polys.contours.items) |c| {
            const pts = self.polys.contour(c);
            if (pts.len < 2) continue;
            try out.path.moveTo(self.gpa, pts[0].scale(1 / fine));
            for (pts[1..]) |p| try out.path.lineTo(self.gpa, p.scale(1 / fine));
            try out.path.close(self.gpa);
        }
        out.winding = sg.winding;
        out.op = sg.op;
    }

    // ------------------------------------------------------------------ shapes

    /// The node's fill shape (`none`: it has none): a formula for rectangles and ellipses
    /// without stored geometry, its curves otherwise.
    fn fillOf(self: *Records, n: *const m.Node, mt: Affine, xf: u32) !u32 {
        if (render.use_geometry and n.geometry.len > 0) return self.pathShape(n, 0, mt, xf);
        switch (n.kind) {
            .frame, .component, .component_set, .instance, .rectangle => return self.boxShape(.rect, .{
                .x1 = n.size.x,
                .y1 = n.size.y,
            }, scene_mod.normRadii(n.size.x, n.size.y, n.radius), xf, mt, .{}),
            .ellipse => return self.boxShape(.ellipse, .{
                .x1 = n.size.x,
                .y1 = n.size.y,
            }, .{ 0, 0, 0, 0 }, xf, mt, .{}),
            .vector => if (n.network) |net| if (net.regions.len > 0) return self.pathShape(n, 0, mt, xf),
            else => {},
        }
        return none;
    }

    const BoxShapeOptions = struct {
        /// The hole cut out of the box; without it, the box is whole.
        inner: ?Rect = null,
        inner_radii: [4]f32 = .{ 0, 0, 0, 0 },
    };

    fn boxShape(self: *Records, kind: ShapeKind, outer: Rect, radii: [4]f32, xf: u32, mt: Affine, options: BoxShapeOptions) !u32 {
        return self.pushShape(.{
            .kind = @backingInt(kind),
            .next = none,
            .xf = xf,
            .flags = if (options.inner != null) 1 else 0,
            .v0 = .{ outer.x0, outer.y0, outer.x1, outer.y1 },
            .v1 = radii,
            .v2 = if (options.inner) |r| .{ r.x0, r.y0, r.x1, r.y1 } else .{ 0, 0, 0, 0 },
            .v3 = options.inner_radii,
            .v6 = .{ outer.x0, outer.y0, outer.x1, outer.y1 },
        }, mt);
    }

    /// The node's path `part` (0 the fill, 1 + i region i) as a shape.
    fn pathShape(self: *Records, n: *const m.Node, part: u32, mt: Affine, xf: u32) !u32 {
        const key: PathKey = .{
            .node = @intFromPtr(n),
            .part = part,
        };
        var got = try self.node_paths.getOrPut(self.gpa, key);
        if (got.found_existing and got.value_ptr.rev != n.shape_rev) {
            got.value_ptr.path.deinit(self.gpa);
            got.found_existing = false;
        }
        if (!got.found_existing) {
            got.value_ptr.* = .{
                .rev = n.shape_rev,
                .path = .{},
                .winding = .nonzero,
            };
            if (part == 0) {
                got.value_ptr.winding = try self.sess.renderer.fillPath(n, &got.value_ptr.path);
            } else {
                const g = n.geometry[part - 1];
                geom.parseSvgPath(self.gpa, g.d, &got.value_ptr.path) catch {};
                got.value_ptr.winding = if (g.winding == .evenodd) .evenodd else .nonzero;
            }
        }
        return self.pathShapeIn(&got.value_ptr.path, got.value_ptr.winding, mt, xf, .{
            .at = &got.value_ptr.at,
        });
    }

    fn pathShapeOf(self: *Records, path: *const Path, winding: mask_mod.Winding, mt: Affine, xf: u32) !u32 {
        return self.pathShapeIn(path, winding, mt, xf, .{});
    }

    const PathShapeOptions = struct {
        /// The path record kept for a node: reused while the path lists are the same.
        /// Without it, the path is written again.
        at: ?*PathAt = null,
    };

    /// `pathShapeOf` reusing the path record `PathShapeOptions.at` holds while the lists are the same
    /// (a top-level node written again after an edit reads the paths it had).
    fn pathShapeIn(self: *Records, path: *const Path, winding: mask_mod.Winding, mt: Affine, xf: u32, options: PathShapeOptions) !u32 {
        if (path.verbs.items.len == 0) return none;
        const pi = if (options.at) |q| (if (q.rec != none and q.gen == self.gen) q.rec else blk: {
            const r = try self.addPath(path);
            q.* = .{
                .rec = r,
                .gen = self.gen,
            };
            break :blk r;
        }) else try self.addPath(path);
        const pr = self.paths.items[pi];
        if (pr.mask != none and winding == .evenodd) self.masks.items[pr.mask].flags = 1;
        if (pr.curve_count == 0) return none;
        const b = path.bounds();
        return self.pushShape(.{
            .kind = @backingInt(ShapeKind.path),
            .next = none,
            .xf = xf,
            .flags = if (winding == .evenodd) 2 else 0,
            .v0 = .{ @bitCast(pi), 0, 0, 0 },
            .v6 = .{ b.x0, b.y0, b.x1, b.y1 },
        }, mt);
    }

    fn pushShape(self: *Records, s: Shape, mt: Affine) !u32 {
        _ = mt;
        const i: u32 = @intCast(self.shapes.items.len);
        try self.shapes.append(self.gpa, s);
        return i;
    }

    /// A clip: shape `s` continuing chain `parent`; the walk's clip bounds shrink to it.
    fn pushClip(self: *Records, s: u32, parent: u32, mt: Affine) !u32 {
        var c = self.shapes.items[s];
        c.next = parent;
        const b = Rect.transformed(.{
            .x0 = c.v6[0],
            .y0 = c.v6[1],
            .x1 = c.v6[2],
            .y1 = c.v6[3],
        }, mt);
        self.clip_box = if (self.clip_box.isEmpty() and parent == none) b else self.clip_box.intersect(b);
        return self.pushShape(c, mt);
    }

    /// Curves of `path` (flattened by the shader as the CPU flattens them): each contour
    /// closed by a line back to its start, as the CPU fills it.
    fn addPath(self: *Records, path: *const Path) !u32 {
        const first: u32 = @intCast(self.curves.items.len);
        var pi: usize = 0;
        var cur: Vec2 = .{};
        var start: Vec2 = .{};
        var open = false;
        const nan = std.math.nan(f32);
        for (path.verbs.items) |v| switch (v) {
            .move => {
                if (open) try self.closeContour(cur, start);
                cur = path.points.items[pi];
                start = cur;
                pi += 1;
                open = true;
            },
            .line => {
                const p = path.points.items[pi];
                pi += 1;
                if (finite(cur) and finite(p)) try self.curves.append(self.gpa, .{ cur.x, cur.y, nan, nan, nan, nan, p.x, p.y });
                cur = p;
            },
            .cubic => {
                const c1 = path.points.items[pi];
                const c2 = path.points.items[pi + 1];
                const p = path.points.items[pi + 2];
                pi += 3;
                if (finite(cur) and finite(c1) and finite(c2) and finite(p)) try self.curves.append(self.gpa, .{ cur.x, cur.y, c1.x, c1.y, c2.x, c2.y, p.x, p.y });
                cur = p;
            },
            .close => {
                if (open) try self.closeContour(cur, start);
                open = false;
                cur = start;
            },
        };
        if (open) try self.closeContour(cur, start);
        const count: u32 = @as(u32, @intCast(self.curves.items.len)) - first;
        const rec = try self.addBands(first, count);
        if (count >= mask_curves) try self.addMask(rec, path);
        return rec;
    }

    /// A coverage mask for path record `rec` (shared with paths of the same curves).
    fn addMask(self: *Records, rec: u32, path: *const Path) !void {
        const pr = self.paths.items[rec];
        const list = self.curves.items[pr.curve_first..][0..pr.curve_count];
        const hash = std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(list));
        if (self.mask_of.get(hash)) |mi| {
            self.paths.items[rec].mask = mi;
            return;
        }
        if (self.masks.items.len >= max_masks) return;
        const b = path.bounds();
        const bw = b.x1 - b.x0;
        const bh = b.y1 - b.y0;
        if (!(bw > 0 and bh > 0) or !std.math.isFinite(bw) or !std.math.isFinite(bh)) return;
        const fs: f32 = @floatFromInt(mask_size - 2);
        const k = fs / @max(bw, bh);
        const mi: u32 = @intCast(self.masks.items.len);
        try self.masks.append(self.gpa, .{
            .path = rec,
            .layer = mi,
            .w = @min(mask_size, @as(u32, @intFromFloat(@ceil(bw * k))) + 2),
            .h = @min(mask_size, @as(u32, @intFromFloat(@ceil(bh * k))) + 2),
            .x0 = b.x0 - 1 / k,
            .y0 = b.y0 - 1 / k,
            .k = k,
            .flags = 0,
        });
        try self.mask_of.put(self.gpa, hash, mi);
        self.paths.items[rec].mask = mi;
    }

    fn closeContour(self: *Records, cur: Vec2, start: Vec2) !void {
        if (cur.x == start.x and cur.y == start.y) return;
        if (!finite(cur) or !finite(start)) return;
        const nan = std.math.nan(f32);
        try self.curves.append(self.gpa, .{ cur.x, cur.y, nan, nan, nan, nan, start.x, start.y });
    }

    /// The path record for curves `first .. first + count`, with its bands.
    fn addBands(self: *Records, first: u32, count: u32) !u32 {
        var y0: f32 = std.math.inf(f32);
        var y1: f32 = -std.math.inf(f32);
        const list = self.curves.items[first..][0..count];
        for (list) |cv| {
            const r = curveY(cv);
            y0 = @min(y0, r[0]);
            y1 = @max(y1, r[1]);
        }
        if (count == 0) {
            y0 = 0;
            y1 = 0;
        }
        const span = y1 - y0;
        // About four curves a band, fewer bands while curves reach over many of them (a
        // pixel row reads each curve once per band).
        var nb: u32 = if (count <= 8 or !(y1 > y0)) 1 else std.math.clamp(count / 4, 1, 1024);
        while (nb > 1) : (nb /= 2) {
            var items: u64 = 0;
            const fnb: f32 = @floatFromInt(nb);
            for (list) |cv| {
                const k = bandRange(curveY(cv), y0, span, fnb, nb);
                items += k[1] - k[0] + 1;
            }
            if (items <= 2 * @as(u64, count)) break;
        }
        const band_first: u32 = @intCast(self.bands.items.len);
        const fb: f32 = @floatFromInt(nb);
        // Count, then fill (each band's curves together).
        const counts = try self.bands.addManyAsSlice(self.gpa, nb);
        for (counts) |*b| b.* = .{ 0, 0 };
        for (list) |cv| {
            const k = bandRange(curveY(cv), y0, span, fb, nb);
            var i = k[0];
            while (i <= k[1]) : (i += 1) counts[i][1] += 1;
        }
        var at: u32 = @intCast(self.band_items.items.len);
        for (counts) |*b| {
            b[0] = at;
            at += b[1];
            b[1] = 0;
        }
        _ = try self.band_items.addManyAsSlice(self.gpa, at - @as(u32, @intCast(self.band_items.items.len)));
        const bands = self.bands.items[band_first..][0..nb];
        for (list, 0..) |cv, ci| {
            const k = bandRange(curveY(cv), y0, span, fb, nb);
            var i = k[0];
            while (i <= k[1]) : (i += 1) {
                self.band_items.items[bands[i][0] + bands[i][1]] = first + @as(u32, @intCast(ci));
                bands[i][1] += 1;
            }
        }
        const pi: u32 = @intCast(self.paths.items.len);
        try self.paths.append(self.gpa, .{
            .curve_first = first,
            .curve_count = count,
            .band_first = band_first,
            .band_count = nb,
            .y0 = y0,
            .y1 = y1,
        });
        return pi;
    }

    // ------------------------------------------------------------------ shadows

    const FormulaShape = struct {
        ellipse: bool,
    };

    /// `Scene.shadowFormula` for records: the node's silhouette is its own rectangle or
    /// ellipse, upright and evenly scaled (its matrix and its top-level node's).
    fn formulaShape(self: *const Records, n: *const m.Node, mt: Affine) ?FormulaShape {
        if (!scene_mod.formula_shadows) return null;
        if (render.use_geometry and n.geometry.len > 0) return null;
        const ellipse = switch (n.kind) {
            .frame, .component, .component_set, .instance, .rectangle => false,
            .ellipse => true,
            else => return null,
        };
        if (!uprightEven(mt)) return null;
        const top = self.top_nodes_current orelse return null;
        if (!uprightEven(top.transform)) return null;
        for (n.effects) |e| {
            if (!e.visible) continue;
            switch (e.kind) {
                .noise, .texture, .layer_blur => return null,
                else => {},
            }
        }
        if (!render.shapeSilhouette(n)) {
            if (n.children.len > 0) return null;
            var any = false;
            for (n.fills) |p| {
                if (!p.visible) continue;
                if (p.kind != .solid) return null;
                any = true;
            }
            if (!any) return null;
            if (scene_mod.hasVisible(n.strokes) and n.stroke.weight > 0 and n.stroke.alignFor(n.kind) != .inside) return null;
        }
        return .{
            .ellipse = ellipse,
        };
    }

    /// A drop shadow by formula: the node's (grown) shape blurred and offset, knocked out
    /// where the node is. Its numbers are node units; the shader takes them to device
    /// pixels as `Scene.formulaShadow` does.
    fn formulaShadow(self: *Records, n: *const m.Node, e: m.Effect, xf: u32, clip: u32, f: FormulaShape) !void {
        const sp = if (scene_mod.Scene.spreads(n)) e.spread else 0;
        const g = scene_mod.Scene.grownBox(n, sp) orelse return;
        const paint = try self.shadowPaint(.{ g.rect.x0, g.rect.y0, g.rect.x1, g.rect.y1 }, g.radii, e, f.ellipse, false);
        var knock: u32 = none;
        if (!e.behind) {
            knock = try self.fillOf(n, self.xformAt(xf), xf);
            if (knock != none and self.shapes.items[knock].kind == @backingInt(ShapeKind.path)) knock = none;
        }
        // Where it reaches: the moved box and three sigmas (node units), two pixels more.
        const reach = 3 * e.radius * render.shadow_k;
        const b: Rect = .{
            .x0 = g.rect.x0 + e.offset.x - reach,
            .y0 = g.rect.y0 + e.offset.y - reach,
            .x1 = g.rect.x1 + e.offset.x + reach,
            .y1 = g.rect.y1 + e.offset.y + reach,
        };
        try self.emit(b, xf, none, knock, if (knock != none) .subtract else .none, clip, paint, n.opacity, .shadow_formula, .normal, 3);
    }

    /// Mirrors `Scene.innerShadow` by formula (rectangles and ellipses, upright); other
    /// inner shadows need surfaces (left out for now).
    fn innerFormula(self: *const Records, n: *const m.Node, mt: Affine, fill: u32) bool {
        for (n.effects) |e| {
            if (!e.visible or e.kind != .inner_shadow) continue;
            // Wide blurs go to the coarse grid on the CPU: passes then.
            if (e.radius * render.shadow_k > render.coarse_sigma / 64) return false;
        }
        return scene_mod.formula_shadows and self.shapes.items[fill].kind != @backingInt(ShapeKind.path) and !(render.use_geometry and n.geometry.len > 0) and uprightEven(mt) and if (self.top_nodes_current) |t| uprightEven(t.transform) else false;
    }

    fn innerShadow(self: *Records, n: *const m.Node, e: m.Effect, mt: Affine, xf: u32, clip: u32, fill: u32) !void {
        _ = mt;
        const ellipse = n.kind == .ellipse;
        const radii = if (ellipse) [4]f32{ 0, 0, 0, 0 } else scene_mod.normRadii(n.size.x, n.size.y, n.radius);
        const paint = try self.shadowPaint(.{ 0, 0, n.size.x, n.size.y }, radii, e, ellipse, true);
        const b = self.shapes.items[fill].v6;
        try self.emit(.{
            .x0 = b[0],
            .y0 = b[1],
            .x1 = b[2],
            .y1 = b[3],
        }, xf, fill, none, .none, clip, paint, 1, .shadow_formula, .normal, 0);
    }

    /// A shadow by formula: two paint records, the box (node units), its radii and colour,
    /// then the effect's offset, radius and spread (node units) and `shadow_k`.
    fn shadowPaint(self: *Records, box: [4]f32, radii: [4]f32, e: m.Effect, ellipse: bool, inner: bool) !u32 {
        const c = colour.solid(e.color);
        const i = try self.pushPaint(.{
            .kind = @backingInt(PaintKind.shadow_formula),
            .flags = @as(u32, @intFromBool(ellipse)) | (@as(u32, @intFromBool(inner)) << 1),
            .a = 0,
            .b = 0,
            .color = pix.premultiply(c.r, c.g, c.b, c.a),
            .inv = box,
            .inv_t = radii,
        }, .{});
        _ = try self.pushPaint(.{
            .kind = 0,
            .flags = 0,
            .a = 0,
            .b = 0,
            .color = .{ e.offset.x, e.offset.y, e.radius, e.spread },
            .inv = .{ render.shadow_k, 0, 0, 0 },
            .inv_t = .{ 0, 0, 0, 0 },
        }, .{});
        return i;
    }

    // ------------------------------------------------------------------ paints and prims

    fn pushPaint(self: *Records, p: Paint, src: PaintSrc) !u32 {
        const i: u32 = @intCast(self.paints.items.len);
        try self.paints.append(self.gpa, p);
        try self.paint_srcs.append(self.gpa, src);
        return i;
    }

    /// Paint `p` of node `n` as a paint record (null: drawn as nothing).
    fn paintFor(self: *Records, n: *const m.Node, p: *const m.Paint) !?u32 {
        const out = try self.paintOut(p, n.size, .{}) orelse return null;
        const i = try self.pushPaint(out, sourceOf(n, p, self.top));
        if (p.kind == .image) try self.image_srcs.put(self.gpa, i, .{
            .paint = p,
            .size = n.size,
        });
        return i;
    }

    const PaintOutOptions = struct {
        /// Where a gradient's stops are written; without it, at the end.
        stops_at: ?u32 = null,
    };

    /// A paint's record (`PaintOutOptions.stops_at`: where a gradient's stops go).
    fn paintOut(self: *Records, p: *const m.Paint, size: Vec2, options: PaintOutOptions) !?Paint {
        var out: Paint = .{
            .kind = 0,
            .flags = 0,
            .a = 0,
            .b = 0,
            .color = .{ 0, 0, 0, 0 },
            .inv = .{ 1, 0, 0, 1 },
            .inv_t = .{ 0, 0, 0, 0 },
        };
        switch (p.kind) {
            .solid => {
                const c = colour.solid(p.color);
                out.kind = @backingInt(PaintKind.solid);
                out.color = pix.premultiply(c.r, c.g, c.b, c.a);
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
                const full = Affine.scaling(size.x, size.y).mul(g);
                const inv = full.invert() orelse return null;
                out.kind = switch (p.kind) {
                    .radial => @backingInt(PaintKind.radial),
                    .angular => @backingInt(PaintKind.angular),
                    .diamond => @backingInt(PaintKind.diamond),
                    else => @backingInt(PaintKind.linear),
                };
                out.a = options.stops_at orelse @intCast(self.stops.items.len);
                out.b = @intCast(p.stops.len);
                for (p.stops, 0..) |st, k| {
                    const c = colour.stop(st.color);
                    if (options.stops_at) |at| {
                        self.stops.items[at + 2 * k] = .{ st.at, 0, 0, 0 };
                        self.stops.items[at + 2 * k + 1] = .{ c.r, c.g, c.b, c.a };
                    } else {
                        try self.stops.append(self.gpa, .{ st.at, 0, 0, 0 });
                        try self.stops.append(self.gpa, .{ c.r, c.g, c.b, c.a });
                    }
                }
                out.inv = .{ inv.a, inv.b, inv.c, inv.d };
                out.inv_t = .{ inv.e, inv.f, 0, 0 };
            },
            .image => {
                const d = if (self.sess.doc) |*d| d else return null;
                const asset = d.asset(p.asset) orelse return null;
                var iw: f32 = @floatFromInt(asset.width);
                var ih: f32 = @floatFromInt(asset.height);
                if (iw <= 0 or ih <= 0) {
                    const mip = self.sess.images.getPtr(p.asset) orelse return null;
                    iw = @floatFromInt(if (mip.width > 0) mip.width else mip.levels[0].w);
                    ih = @floatFromInt(if (mip.height > 0) mip.height else mip.levels[0].h);
                }
                const n2i = render.imageSpace(p, size, iw, ih) orelse return null;
                out.kind = @backingInt(PaintKind.image);
                out.flags = @as(u32, @intFromBool(p.scale == .tile)) | (@as(u32, @intFromBool(p.scale == .fit or p.scale == .crop)) << 1);
                out.a = try self.imageIndex(p.asset, @intFromFloat(iw), @intFromFloat(ih));
                out.inv = .{ n2i.a, n2i.b, n2i.c, n2i.d };
                out.inv_t = .{ n2i.e, n2i.f, iw, ih };
            },
            .pattern => return null,
        }
        return out;
    }

    fn imageIndex(self: *Records, hash: []const u8, w: u32, h: u32) !u32 {
        const got = try self.image_of.getOrPut(self.gpa, hash);
        if (got.found_existing) return got.value_ptr.*;
        const i: u32 = @intCast(self.images.items.len);
        got.value_ptr.* = i;
        try self.images.append(self.gpa, .{
            .hash_ptr = addr(hash.ptr),
            .hash_len = @intCast(hash.len),
            .width = w,
            .height = h,
        });
        try self.image_hashes.append(self.gpa, hash);
        return i;
    }

    fn addPrim(self: *Records, shape: u32, shape2: u32, op: Op, clip: u32, paint: u32, opacity: f32, feature: Feature, xf: u32, blend: pix.BlendMode) !void {
        const b = self.shapes.items[shape].v6;
        try self.emit(.{
            .x0 = b[0],
            .y0 = b[1],
            .x1 = b[2],
            .y1 = b[3],
        }, xf, shape, shape2, op, clip, paint, opacity, feature, blend, 0);
    }

    /// A prim over `bounds` (node space, through `xf`), cut to the clip chain's bounds.
    fn emit(self: *Records, bounds: Rect, xf: u32, shape: u32, shape2: u32, op: Op, clip: u32, paint: u32, opacity: f32, feature: Feature, blend: pix.BlendMode, margin: f32) !void {
        var b = Rect.transformed(bounds, self.xformAt(xf));
        if (clip != none and !self.clip_box.isEmpty()) b = b.intersect(self.clip_box);
        if (b.isEmpty() and clip != none) return;
        const pi: u32 = @intCast(self.prims.items.len);
        try self.prims.append(self.gpa, .{
            .x0 = b.x0,
            .y0 = b.y0,
            .x1 = b.x1,
            .y1 = b.y1,
            .shape = shape,
            .shape2 = shape2,
            .clip = clip,
            .paint = paint,
            .op = @backingInt(op),
            .xf = xf,
            .top = self.top,
            .feature = @backingInt(feature),
            .opacity = opacity * self.alpha,
            .blend = @backingInt(scene_mod.Blend.of(blend)),
            .owner = self.owner,
            .margin = margin,
        });
        self.header.features[@backingInt(feature)] += 1;
        const pt = self.paints.items[paint];
        const tex = if (pt.kind == @backingInt(PaintKind.image)) pt.a else none;
        if (pt.kind == @backingInt(PaintKind.image)) if (self.image_srcs.get(paint)) |src| {
            try self.image_uses.append(self.gpa, .{
                .top = self.top,
                .xf = xf,
                .paint = src.paint,
                .size = src.size,
                .rect = b,
            });
        };
        if (self.draws.items.len > self.draws_from) {
            const last = &self.draws.items[self.draws.items.len - 1];
            if (last.kind == Draw.prims and last.top == self.top and last.first + last.count == pi and (tex == none or last.tex == none or last.tex == tex)) {
                last.count += 1;
                if (tex != none) last.tex = tex;
                return;
            }
        }
        try self.draws.append(self.gpa, .{
            .kind = Draw.prims,
            .first = pi,
            .count = 1,
            .tex = tex,
            .top = self.top,
        });
    }
};

/// Whether `n` (or a node under it it does not isolate) reads what lies under it.
fn readsBackdrop(n: *const m.Node) bool {
    if (!n.visible) return false;
    if (n.blend != .pass_through and n.blend != .normal) return true;
    for ([2][]const m.Paint{ n.fills, n.strokes }) |ps| for (ps) |p| {
        if (p.visible and p.blend != .normal) return true;
    };
    for (n.effects) |e| if (e.visible and e.kind == .background_blur) return true;
    for (n.children) |*c| if (readsBackdrop(c)) return true;
    return false;
}

/// Whether a visible paint of the node is a pattern (drawn by an item: its tiles are
/// other nodes).
fn hasPattern(n: *const m.Node) bool {
    for ([2][]const m.Paint{ n.fills, n.strokes }) |ps| for (ps) |p| {
        if (p.visible and p.kind == .pattern) return true;
    };
    return false;
}

fn hasEffects(n: *const m.Node) bool {
    for (n.effects) |e| if (e.visible) return true;
    return false;
}

fn uprightEven(t: Affine) bool {
    return t.b == 0 and t.c == 0 and t.a == t.d and t.a > 0;
}

fn finite(p: Vec2) bool {
    return std.math.isFinite(p.x) and std.math.isFinite(p.y);
}

/// The y range of a curve's control points.
fn curveY(cv: Curve) [2]f32 {
    var lo = @min(cv[1], cv[7]);
    var hi = @max(cv[1], cv[7]);
    if (cv[2] == cv[2]) {
        lo = @min(lo, @min(cv[3], cv[5]));
        hi = @max(hi, @max(cv[3], cv[5]));
    }
    return .{ lo, hi };
}

/// The bands `y` (a curve's range) reaches.
fn bandRange(y: [2]f32, y0: f32, span: f32, fb: f32, nb: u32) [2]u32 {
    if (nb <= 1 or !(span > 0)) return .{ 0, 0 };
    const k0 = std.math.clamp(@floor((y[0] - y0) / span * fb), 0, fb - 1);
    const k1 = std.math.clamp(@floor((y[1] - y0) / span * fb), 0, fb - 1);
    return .{ @intFromFloat(k0), @intFromFloat(k1) };
}

/// Whether nothing in `n`'s subtree changed but colours since revision `since`.
fn unchangedSince(n: *const m.Node, since: u32) bool {
    if (n.tree_rev <= since) return true;
    if (n.rev > since) return false;
    for (n.children) |*c| if (!unchangedSince(c, since)) return false;
    return true;
}

/// Where paint `p` of node `n` is (`top`: the top-level node being written).
fn sourceOf(n: *const m.Node, p: *const m.Paint, top: u32) PaintSrc {
    const in = struct {
        fn list(ps: []const m.Paint, q: *const m.Paint) ?u32 {
            if (ps.len == 0) return null;
            const a = @intFromPtr(ps.ptr);
            const at = @intFromPtr(q);
            if (at < a or at >= a + ps.len * @sizeOf(m.Paint)) return null;
            return @intCast((at - a) / @sizeOf(m.Paint));
        }
    };
    var src: PaintSrc = .{
        .node = n,
        .top = top,
    };
    if (in.list(n.fills, p)) |i| {
        src.list = 1;
        src.index = i;
    } else if (in.list(n.strokes, p)) |i| {
        src.list = 2;
        src.index = i;
    } else {
        if (n.text) |t| for (t.runs, 0..) |r, ri| if (r.fills) |f| if (in.list(f, p)) |i| {
            src.list = 3;
            src.at = @intCast(ri);
            src.index = i;
            return src;
        };
        for (n.geometry, 0..) |g, gi| if (g.fills) |f| if (in.list(f, p)) |i| {
            src.list = 4;
            src.at = @intCast(gi);
            src.index = i;
            return src;
        };
        // Not one of the node's lists: never painted again in place.
        src.node = null;
    }
    return src;
}

/// The paint `src` names, read from its node now (null: its list no longer has it).
fn paintAt(n: *const m.Node, src: PaintSrc) ?*const m.Paint {
    const list: []const m.Paint = switch (src.list) {
        1 => n.fills,
        2 => n.strokes,
        3 => blk: {
            const t = n.text orelse return null;
            if (src.at >= t.runs.len) return null;
            break :blk t.runs[src.at].fills orelse return null;
        },
        4 => blk: {
            if (src.at >= n.geometry.len) return null;
            break :blk n.geometry[src.at].fills orelse return null;
        },
        else => return null,
    };
    if (src.index >= list.len) return null;
    return &list[src.index];
}

/// Whether paint `p` is painted again into record `r` (made from a paint of its kind,
/// with as many stops).
fn fits(p: *const m.Paint, r: Paint) bool {
    return switch (p.kind) {
        .solid => r.kind == @backingInt(PaintKind.solid),
        .linear => r.kind == @backingInt(PaintKind.linear) and r.b == p.stops.len,
        .radial => r.kind == @backingInt(PaintKind.radial) and r.b == p.stops.len,
        .angular => r.kind == @backingInt(PaintKind.angular) and r.b == p.stops.len,
        .diamond => r.kind == @backingInt(PaintKind.diamond) and r.b == p.stops.len,
        .image => r.kind == @backingInt(PaintKind.image),
        .pattern => false,
    };
}

/// What an item's pictures are kept by: its node, part and subtree revision, and its
/// matrix to its top-level node.
fn itemKey(n: *const m.Node, kind: u32, child: u32, mt: [6]f32) u64 {
    const Key = extern struct {
        node: u64,
        kind: u32,
        child: u32,
        rev: u32,
        xf: [6]f32,
    };
    const kb: Key = .{
        .node = @intFromPtr(n),
        .kind = kind,
        .child = child,
        .rev = n.tree_rev,
        .xf = mt,
    };
    return std.hash.Wyhash.hash(7, std.mem.asBytes(&kb));
}

fn freeText(gpa: Allocator, tc: *TextCache) void {
    for (tc.file) |*tp| tp.path.deinit(gpa);
    if (tc.file.len > 0) gpa.free(tc.file);
    if (tc.file_recs.len > 0) gpa.free(tc.file_recs);
    tc.lay.deinit(gpa);
}

fn addr(p: anytype) u32 {
    return @truncate(@intFromPtr(p));
}

test "records: a page written once, a top-level node written again after an edit" {
    const gpa = std.testing.allocator;
    var s = try Session.create(gpa);
    defer s.destroy();
    try s.loadPubd(
        \\{"pubd":0,"name":"t","pages":[{"id":"0:1","type":"page","name":"P","children":[
        \\{"id":"1:1","type":"frame","name":"F","transform":[1,0,0,1,10,20],"size":[16,16],"radius":[4,4,4,4],
        \\"fills":[{"type":"solid","color":"#ff0000"}],"clip":true,"children":[
        \\{"id":"1:2","type":"vector","name":"V","transform":[1,0,0,1,2,2],"size":[10,10],
        \\"fills":[{"type":"solid","color":"#0000ff"}],"geometry":[{"d":"M0 0C5 0 10 5 10 10L0 10Z"}]},
        \\{"id":"1:3","type":"rectangle","name":"S","transform":[1,0,0,1,4,4],"size":[8,8],"opacity":0.5,
        \\"fills":[{"type":"solid","color":"#00ff00"},{"type":"solid","color":"#0000ff80"}]}]},
        \\{"id":"2:1","type":"rectangle","name":"R","transform":[1,0,0,1,100,0],"size":[20,20],
        \\"fills":[{"type":"solid","color":"#000000"}],"effects":[{"type":"drop-shadow","color":"#0000004d","offset":[0,4],"radius":8}]}]}]}
    );
    var rec = Records.init(gpa);
    defer rec.deinit();
    try rec.build(s, 0);
    try std.testing.expectEqual(@as(u32, 1), rec.header.full);
    try std.testing.expectEqual(@as(usize, 2), rec.tops.items.len);
    // The frame's fill, the vector's curves (a cubic, a line, the closing line), the
    // see-through group as an item with its plain prims, the rectangle's formula shadow.
    try std.testing.expectEqual(@as(u32, 3), rec.paths.items[0].curve_count);
    try std.testing.expectEqual(@as(usize, 1), rec.items.items.len);
    try std.testing.expectEqual(Item.node, rec.items.items[0].kind);
    try std.testing.expect(rec.header.features[@backingInt(Feature.shadow_formula)] == 1);
    // A frame: one camera per top-level node, both in view.
    try rec.frame(s, 0, 0, 2, 400, 200);
    try std.testing.expectEqual(@as(u32, 2), rec.frame_header.visible_count);
    try std.testing.expectEqual(@as(i32, 20), rec.cameras.items[0].ox);
    // Nothing changed: nothing written.
    try rec.update(s, 0);
    try std.testing.expectEqual(@as(u32, 2), rec.header.full);
    // The first node changed: only it is written again, at the ends of the lists.
    const prims_before = rec.prims.items.len;
    const top1 = rec.tops.items[1];
    const pages = s.pages();
    pages[0].children[0].tree_rev += 1;
    pages[0].children[0].rev = pages[0].children[0].tree_rev;
    try rec.update(s, 0);
    try std.testing.expectEqual(@as(u32, 0), rec.header.full);
    try std.testing.expect(rec.tops.items[0].prim_first >= prims_before);
    try std.testing.expectEqual(top1.prim_first, rec.tops.items[1].prim_first);
    // Its old item is retired, the new one stands.
    try std.testing.expectEqual(none, rec.items.items[0].top);
    try std.testing.expectEqual(@as(u32, 0), rec.items.items[1].top);
    // The vector's path record is read again, not written again.
    try std.testing.expectEqual(@as(usize, 1), rec.paths.items.len);
    // Every node changed again and again: once the lists are mostly unread, they are
    // written again from their starts, the paths kept.
    var full: u32 = 0;
    var edits: usize = 0;
    while (full != 3 and edits < 10000) : (edits += 1) {
        for (pages[0].children) |*c| {
            c.tree_rev += 1;
            c.rev = c.tree_rev;
        }
        try rec.update(s, 0);
        full = rec.header.full;
    }
    try std.testing.expectEqual(@as(u32, 3), full);
    try std.testing.expectEqual(@as(usize, 1), rec.paths.items.len);
    var live: usize = 0;
    for (rec.tops.items) |t| live += t.prim_count;
    try std.testing.expectEqual(live, rec.prims.items.len);
    try std.testing.expectEqual(@as(usize, 1), rec.items.items.len);
    try std.testing.expectEqual(@as(u32, 0), rec.items.items[0].top);
}
