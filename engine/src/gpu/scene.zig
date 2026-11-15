//! The GPU canvas's frame: the scene walked the way the CPU renderer walks it and written
//! out as flat lists in draw order (`docs/gpu.md` is the binary layout the host reads).
//!
//! Shapes are formulas the fragment shader evaluates at Figma's 16 sample points
//! (rectangles, rounded rectangles, ellipses, rings), or paths whose coverage the host
//! rasterises into an atlas first (stencil and cover, 4x MSAA at twice the resolution:
//! the same 16 points in hardware). Every primitive carries its paint (solid, gradient,
//! image) and its clip chain. What the GPU cannot draw yet falls back to the CPU per node:
//! the scene names the node (or the part of it: its drop shadows, its inner shadows, a
//! mask and what it masks) and where it goes in the draw order, and the host composites
//! the CPU's pixels there.
//!
//! Coordinates: every top-level node is drawn in its own device space ("top space"), the
//! one a CPU tile draws it in (`Session.place`): its origin sits at a fraction of a pixel,
//! and the whole-pixel offset to the viewport travels with each primitive. A node's
//! numbers are then the CPU's numbers, and they do not change while the view pans by
//! whole device pixels.

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

const Affine = geom.Affine;
const IRect = mask_mod.IRect;
const Path = geom.Path;
const Polylines = geom.Polylines;
const Vec2 = geom.Vec2;
const Session = session_mod.Session;
const Allocator = std.mem.Allocator;

/// The WGSL the host compiles: the primitives, the path atlas, the canvas, the effect
/// passes.
pub const shaders = struct {
    pub const paint = @embedFile("common.wgsl") ++ @embedFile("paint.wgsl");
    pub const atlas = @embedFile("atlas.wgsl");
    pub const present = @embedFile("present.wgsl");
    pub const effects = @embedFile("effects.wgsl");
    pub const scaled = @embedFile("scaled.wgsl");
};

/// The binary layout's version (`docs/gpu.md`); bumped when a record changes.
pub const layout_version: u32 = 3;

/// No index: no shape, clip, paint or texture.
pub const none: u32 = std.math.maxInt(u32);

/// Draw shadows of rectangles and ellipses by formula (off: always by passes, to compare).
pub var formula_shadows = true;

/// The longest side of a surface, in pixels (a texture's limit).
pub const max_surface: u32 = 8192;

// What a surface draws (part of its key).
const part_content: u32 = 0;
const part_opaque: u32 = 1;
const part_shadow: u32 = 2;
const part_inner: u32 = 3;
const part_coarse: u32 = 4;
const part_pattern: u32 = 5;
const part_mask: u32 = 6;
const part_masked: u32 = 7;
const part_clip: u32 = 8;
const part_backdrop: u32 = 9;
const part_cover: u32 = 10;

/// Side of an atlas layer, in texels (two per device pixel each way).
pub const atlas_size: u32 = 2048;
/// Empty texels around each atlas entry (fan triangles may reach a pixel past it).
const atlas_pad: u32 = 4;
/// Paths are cut into cells this many device pixels wide, one atlas entry each.
pub const cell: i32 = 1016;
/// Side of the glyph atlas (one texel per device pixel).
pub const glyph_atlas_size: u32 = 4096;
/// Glyphs larger than this (device pixels per em) are drawn as paths.
pub const glyph_max_em: f32 = 128;
/// New glyph masks a frame rasterises at most: a style with more new glyphs than are
/// left draws as paths this frame and takes its masks over the next ones (zooming makes
/// every glyph new).
pub var glyph_budget: u32 = 400;

/// One quad on screen: its pixels get the paint, times the coverage of its shape (and
/// of `shape2`, kept or cut out), its clip chain and its opacity.
pub const Prim = extern struct {
    /// The quad, in viewport device pixels.
    x0: f32,
    y0: f32,
    x1: f32,
    y1: f32,
    shape: u32,
    shape2: u32,
    /// The first clip of the chain (a shape whose `next` continues it).
    clip: u32,
    paint: u32,
    op: u32,
    /// The top-level node's whole-pixel offset: viewport = top space + (ox, oy).
    ox: i32,
    oy: i32,
    /// What the primitive draws (`Feature`), for counts.
    feature: u32,
    opacity: f32,
    /// Bits 0..7: how it composites (`Blend`); bits 8..15: how `mask` scales its
    /// coverage (`MaskMode`).
    blend: u32 = 0,
    /// A second paint whose alpha (or luminance) scales the coverage (`none`: none).
    mask: u32 = none,
    pad2: u32 = 0,
};

/// How a primitive composites onto its target: source-over (normal), one of the
/// separable and non-separable blend modes (`pix.BlendMode`'s order), or `lerp` (the
/// target moves toward the paint by the coverage, as a background blur replaces what is
/// behind it).
pub const Blend = enum(u32) {
    normal = 0,
    lerp = 31,
    _,

    pub fn of(b: pix.BlendMode) Blend {
        return @fromBackingInt(@intCast(@backingInt(b)));
    }
};

/// How a prim's mask paint scales its coverage.
pub const MaskMode = enum(u32) {
    none = 0,
    alpha = 1,
    luminance = 2,
    /// One minus the alpha: a drop shadow knocked out where its node is.
    inverse_alpha = 3,
};

pub const Op = enum(u32) {
    none = 0,
    /// Coverage times `shape2`'s.
    intersect = 1,
    /// Coverage times one minus `shape2`'s.
    subtract = 2,
};

pub const Feature = enum(u32) {
    fill_formula = 1,
    fill_path = 2,
    stroke_ring = 3,
    stroke_path = 4,
    text = 5,
    fallback = 6,
    /// An offscreen surface composited (group opacity, blend modes, masks, patterns,
    /// effects).
    layer = 7,
    /// A shadow by formula (one quad, no passes).
    shadow_formula = 8,
    /// A shadow from a blurred surface.
    shadow_pass = 9,
};

pub const ShapeKind = enum(u32) {
    /// A rectangle with per-corner radii, and maybe a hole (`inner`, the even-odd ring).
    rect = 1,
    ellipse = 2,
    /// Coverage from the path atlas.
    atlas = 3,
};

pub const Shape = extern struct {
    kind: u32,
    /// The next clip of a chain (`none`: the last).
    next: u32,
    /// Atlas: the layer.
    layer: u32,
    /// Bit 0: `inner` is a hole.
    flags: u32,
    /// Top space to the shape's space: a, b, c, d (`x' = a*x + c*y + e`).
    inv: [4]f32,
    /// e, f, unused, unused.
    inv_t: [4]f32,
    /// x0, y0, x1, y1 in the shape's space; atlas: the entry's pixels in top space.
    outer: [4]f32,
    /// Corner radii: top left, top right, bottom right, bottom left; atlas: the texel
    /// of the entry's top left pixel (x, y).
    outer_r: [4]f32,
    inner: [4]f32,
    inner_r: [4]f32,
    pad: [4]f32 = .{ 0, 0, 0, 0 },
};

pub const PaintKind = enum(u32) {
    solid = 1,
    linear = 2,
    radial = 3,
    angular = 4,
    diamond = 5,
    image = 6,
    /// A surface (or a CPU layer of a fallback), placed by `inv` (top space to its
    /// texels; `a` the surface). Flags bit 0: filtered (bilinear, centres at .5).
    texture = 7,
    /// A shadow: `color` times the surface's alpha, bilinear at `inv` of the pixel's
    /// centre less half a texel (`a` the surface).
    shadow = 8,
    /// A shadow by formula: `color` times a box (or ellipse) with corner radii blurred by
    /// a Gaussian of sigma `b` (f32 bits). `inv` holds the box (x0, y0, x1, y1, top
    /// space), `inv_t` the radii. Flags bit 0: ellipse; bit 1: inner (one minus it).
    shadow_formula = 9,
};

pub const Paint = extern struct {
    kind: u32,
    /// Images: bit 0 tile, bit 1 decal. Textures: bit 0 filtered (a stand-in, scaled).
    flags: u32,
    /// Gradients: the first stop. Images: the texture.
    a: u32,
    /// Gradients: the stop count. Images: the mip levels.
    b: u32,
    /// Solid: premultiplied colour.
    color: [4]f32,
    /// Top space to paint space (gradient space, image pixels, texture texels): a, b, c, d.
    inv: [4]f32,
    /// e, f, then the image's width and height (level 0).
    inv_t: [4]f32,
};

pub const Draw = extern struct {
    kind: u32,
    first: u32,
    count: u32,
    /// Kind 0: the texture the prims' paints read: an image, or a surface
    /// (`surface_bit` | index); `none`: none. Kind 1: the fallback.
    tex: u32,
    /// Kind 0: the texture their mask paints read (`none`: none).
    mask: u32 = none,
    /// Kind 0: bit 0, the prims read what is under them (one prim; the host copies its
    /// pixels of the target first); bit 1, they composite by maximum (silhouettes).
    flags: u32 = 0,
    pad0: u32 = 0,
    pad1: u32 = 0,

    pub const prims: u32 = 0;
    pub const fallback: u32 = 1;
    /// Later draws go to surface `first` (cleared) until its `end`.
    pub const begin: u32 = 2;
    /// Back to the target before the surface's `begin`.
    pub const end: u32 = 3;
    /// Effect pass `first` runs here.
    pub const pass: u32 = 4;

    pub const backdrop: u32 = 1;
    pub const max: u32 = 2;
    /// The target times one minus the prims' alpha.
    pub const erase: u32 = 4;
};

/// Textures of surfaces in `Draw.tex` and `Draw.mask`.
pub const surface_bit: u32 = 1 << 31;

/// An offscreen target: `w` x `h` premultiplied pixels, texel (0, 0) the pixel
/// (`x0`, `y0`) of its space (the top space it is drawn in, or a coarse grid).
pub const Surface = extern struct {
    w: u32,
    h: u32,
    x0: i32,
    y0: i32,
    /// Bit 0: its pixels depend only on its draws (none reads a backdrop, no CPU layer),
    /// so the host may keep them for later frames under `key`.
    flags: u32,
    key_lo: u32,
    key_hi: u32,
    /// The node and part it draws, whatever the matrix: stand-ins at other scales.
    base: u32,
    /// The index of its `end` draw (a kept surface skips to there).
    end: u32,
    /// The node's matrix to this space (stand-ins map between two of them).
    ctm: [6]f32,
    pad: u32 = 0,

    pub const cacheable: u32 = 1;
};

/// An effect pass on surfaces, run on the GPU with the CPU renderer's numbers (kernels,
/// box sizes, seeds).
pub const PassKind = enum(u32) {
    /// Separable Gaussian: `f[0]` sigma, `i[0]` the kernel's radius; outside is clear.
    gauss = 1,
    /// Three box blurs (rows then columns each), half widths `i[0..3]`.
    box3 = 2,
    /// The progressive blur: sigma per pixel from the ramp in `f` (`effects.Ramp`).
    progressive = 3,
    /// Grows (`i[1]` 1) or shrinks the alpha by `i[0]` + `f[0]` pixels (a square
    /// max or min filter, the fraction blended).
    spread = 4,
    /// Grain over the surface (`effects.drawNoise`).
    noise = 5,
    /// Displacement (`effects.drawTexture`) from `src` into `dst`.
    texture = 6,
    /// The current target's pixels into `dst`, mirrored at `i[0..4]` (top space);
    /// target texel = top + (`i[4]`, `i[5]`).
    backdrop = 7,
};

pub const Pass = extern struct {
    kind: u32,
    src: u32,
    dst: u32,
    pad: u32 = 0,
    i: [8]i32 = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
    f: [20]f32 = @splat(0),
};

pub const AtlasEntry = extern struct {
    layer: u32,
    /// 0 nonzero, 1 even-odd.
    rule: u32,
    /// The entry's texels with its padding (what the cover pass covers).
    x: u32,
    y: u32,
    w: u32,
    h: u32,
    pad0: u32 = 0,
    pad1: u32 = 0,
};

pub const AtlasLayer = extern struct {
    /// Triangle vertices (two f32 each, layer texels) of this layer's stencil pass.
    vert_first: u32,
    vert_count: u32,
    entry_first: u32,
    entry_count: u32,
    /// Glyph masks added into this layer after the stencil pass.
    glyph_first: u32,
    glyph_count: u32,
    pad0: u32 = 0,
    pad1: u32 = 0,
};

/// A glyph mask from the glyph atlas added into a path atlas entry (each mask texel
/// over 2x2 texels there, coverage summed).
pub const GlyphDraw = extern struct {
    layer: u32,
    /// Where it lands: path atlas texels.
    dx: u32,
    dy: u32,
    /// Its size in device pixels.
    w: u32,
    h: u32,
    /// Where it comes from: glyph atlas texels.
    sx: u32,
    sy: u32,
    pad: u32 = 0,
};

/// A glyph mask new this frame, for the host to write into the glyph atlas: `w * h`
/// coverage bytes at `ptr` (natively: at offset `ptr` of `Scene.glyph_bytes`), at (`x`, `y`).
pub const GlyphUpload = extern struct {
    x: u32,
    y: u32,
    w: u32,
    h: u32,
    ptr: u32,
    pad0: u32 = 0,
    pad1: u32 = 0,
    pad2: u32 = 0,
};

/// A glyph rasterised at one size and sub-pixel position: what its mask depends on
/// besides whole-pixel moves.
const GlyphKey = struct {
    font: usize,
    glyph: u16,
    /// Device pixels per font unit, bits.
    scale: u32,
    /// The origin's fraction of a device pixel, bits.
    fx: u32,
    fy: u32,
};

const GlyphSlot = struct {
    x: u32,
    y: u32,
    w: u32,
    h: u32,
    /// The mask's top left from the origin's whole pixel.
    ox: i32,
    oy: i32,
};

/// A glyph of the style being drawn: its mask's key, its origin (device), and the mask
/// when the atlas has it.
const GlyphPick = struct {
    g: text_layout.Placed,
    key: GlyphKey,
    d: Vec2,
    slot: ?GlyphSlot,
};

/// A glyph placed this frame: its mask's pixels in top space and where the mask is.
const GlyphRect = struct {
    rect: IRect,
    sx: u32,
    sy: u32,
};

pub const Texture = extern struct {
    hash_ptr: u32,
    hash_len: u32,
    width: u32,
    height: u32,
    levels: u32,
    pad0: u32 = 0,
    pad1: u32 = 0,
    pad2: u32 = 0,
};

/// Why a node falls back to the CPU.
pub const Reason = enum(u32) {
    text = 1,
    effect = 2,
    blend = 3,
    opacity = 4,
    pattern = 5,
    paint_blend = 6,
    clip_path = 7,
    shadow = 8,
    inner_shadow = 9,
    mask = 10,
};

pub const Fallback = extern struct {
    id_ptr: u32,
    id_len: u32,
    /// `Session.LayerPart`.
    part: u32,
    /// The child a mask run starts at.
    child: u32,
    reason: u32,
    /// The prim that carries the clip and offset (not drawn itself).
    prim: u32,
    /// The node's subtree revision: a layer drawn before an edit of it is stale.
    rev: u32 = 0,
    pad1: u32 = 0,
    /// Node space to top space.
    ctm: [6]f32,
    pad2: [2]f32 = .{ 0, 0 },
    /// Where the part shows: top space, x0, y0, x1, y1.
    rect: [4]i32,
    /// Everything the part may paint (top space), in view or not: layers are cut from it.
    full: [4]i32,
};

/// Where every list starts and how long it is (pointers into the engine's memory).
pub const Header = extern struct {
    version: u32 = layout_version,
    prims: u32 = 0,
    prim_count: u32 = 0,
    shapes: u32 = 0,
    shape_count: u32 = 0,
    paints: u32 = 0,
    paint_count: u32 = 0,
    stops: u32 = 0,
    /// vec4s: each stop is two (offset, then straight colour).
    stop_count: u32 = 0,
    draws: u32 = 0,
    draw_count: u32 = 0,
    entries: u32 = 0,
    entry_count: u32 = 0,
    layers: u32 = 0,
    layer_count: u32 = 0,
    verts: u32 = 0,
    vert_count: u32 = 0,
    textures: u32 = 0,
    texture_count: u32 = 0,
    fallbacks: u32 = 0,
    fallback_count: u32 = 0,
    /// Nodes walked and culled.
    nodes: u32 = 0,
    culled: u32 = 0,
    /// Primitives per `Feature` (index = the feature's number).
    features: [12]u32 = @splat(0),
    /// Fallbacks per `Reason`.
    reasons: [12]u32 = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    glyph_uploads: u32 = 0,
    glyph_upload_count: u32 = 0,
    glyph_draws: u32 = 0,
    glyph_draw_count: u32 = 0,
    /// Glyphs in the glyph atlas (cached between frames).
    glyphs_cached: u32 = 0,
    /// Text styles drawn as paths for want of budget: the next frame should follow.
    glyphs_deferred: u32 = 0,
    surfaces: u32 = 0,
    surface_count: u32 = 0,
    passes: u32 = 0,
    pass_count: u32 = 0,
    /// Device pixels the frame's target holds around the view on each side (what a
    /// background blur reads past the view's edge, as a CPU tile's apron).
    apron: u32 = 0,
    /// Pixels of every surface this frame (before what the host keeps).
    surface_pixels: u32 = 0,
};

/// Node-space paths, kept between frames.
const PathKey = struct {
    node: usize,
    /// 0 the fill, 1 + i region geometry i.
    part: u32,
};

/// Top-space polylines of a node's path under one matrix: panning by whole pixels keeps
/// the matrix, so the next frame takes them as they are.
const DevKey = struct {
    node: usize,
    /// 0 the fill, 1 + i region i, `stroke_part` the stroke, `text_part` + i text style i.
    part: u32,
    ctm: [6]u32,
};

const stroke_part: u32 = 1 << 20;
const text_part: u32 = 1 << 21;
const glyph_part: u32 = 1 << 19;

const DevPolys = struct {
    polys: Polylines,
    bounds: geom.Rect,
    winding: mask_mod.Winding,
    /// Stroke: how the fill cuts it, and whether the node has a fill path.
    op: render.StrokeGeometry.Op = .none,
    has_fill: bool = false,
    /// Moved from another scale's polylines while the view moved: not the CPU's numbers.
    approx: bool = false,
    /// The last frame that used them.
    stamp: u32,
};

/// A text node kept between frames: its layout (glyphs point at fonts it holds) and its
/// styles as paths.
const TextCache = struct {
    lay: text_layout.Layout,
    styles: []render.TextPath,
};

const CachedPath = struct {
    path: Path,
    winding: mask_mod.Winding,
};

/// A stroke's coverage for a pattern: its atlas shapes, how the fill cuts them, where.
const StrokeCover = struct {
    chunks: Chunks,
    op: Op,
    bounds: geom.Rect,
};

/// A path's atlas entries: one shape per cell it covers.
const Chunks = struct {
    first: u32,
    count: u32,
};

/// A node's fill as the GPU draws it.
const Fill = union(enum) {
    none,
    /// A shape with no pixels in view.
    hidden,
    formula: u32,
    path: Chunks,
};

pub const Scene = struct {
    gpa: Allocator,
    prims: std.ArrayList(Prim) = .empty,
    shapes: std.ArrayList(Shape) = .empty,
    /// Each shape's pixels in top space (clips: already cut by their chain).
    shape_bounds: std.ArrayList(IRect) = .empty,
    /// Atlas shapes: the cell they stand for.
    shape_cells: std.ArrayList([2]i32) = .empty,
    paints: std.ArrayList(Paint) = .empty,
    stops: std.ArrayList([4]f32) = .empty,
    draws: std.ArrayList(Draw) = .empty,
    entries: std.ArrayList(AtlasEntry) = .empty,
    layers: std.ArrayList(AtlasLayer) = .empty,
    verts: std.ArrayList([2]f32) = .empty,
    textures: std.ArrayList(Texture) = .empty,
    /// Each texture's asset hash (the decoded images map may move its values).
    texture_hashes: std.ArrayList([]const u8) = .empty,
    /// Each texture's first level in the image's full chain (`Mipmap.first`) when the
    /// scene took it: a later paint of the same image may decode it finer while the
    /// scene is built, and its levels are then found by their place in the full chain.
    texture_first: std.ArrayList(u8) = .empty,
    fallbacks: std.ArrayList(Fallback) = .empty,
    /// Each fallback's node id (a native host reads it here: the header's addresses are
    /// 32-bit, the WASM engine's).
    fallback_ids: std.ArrayList([]const u8) = .empty,
    /// Per fallback, its node's `tree_rev`: a host keeping layer pictures keys them by it,
    /// so a node whose content changed under the same id is drawn again.
    fallback_revs: std.ArrayList(u32) = .empty,
    surfaces: std.ArrayList(Surface) = .empty,
    passes: std.ArrayList(Pass) = .empty,
    /// Surfaces begun and not yet ended, innermost last.
    open: std.ArrayList(u32) = .empty,
    /// The node whose own paints draw opaque (its shadow silhouette).
    opaque_of: ?*const m.Node = null,
    texture_of: std.StringHashMapUnmanaged(u32) = .empty,
    paths: std.AutoHashMapUnmanaged(PathKey, CachedPath) = .empty,
    dev: std.AutoHashMapUnmanaged(DevKey, DevPolys) = .empty,
    /// Frames built so far (for dropping polylines no frame uses).
    stamp: u32 = 0,
    /// The view is moving: polylines of a nearby scale stand in for this frame's, text
    /// draws as paths and no surface is kept (the host draws an exact frame once it
    /// settles).
    motion: bool = false,
    /// The polylines each node part was last filled with exactly, for stand-ins.
    recent: std.AutoHashMapUnmanaged(PathKey, DevKey) = .empty,
    /// Whether a node's pixels depend on what lies under it (blend modes, background
    /// blur), through the children it does not isolate; by node, kept between frames.
    backdrop: std.AutoHashMapUnmanaged(usize, bool) = .empty,
    /// Text nodes' style paths (node space) by node, kept between frames.
    texts: std.AutoHashMapUnmanaged(usize, TextCache) = .empty,
    /// Glyph masks in the glyph atlas, kept between frames.
    glyphs: std.AutoHashMapUnmanaged(GlyphKey, GlyphSlot) = .empty,
    glyph_x: u32 = 0,
    glyph_y: u32 = 0,
    glyph_h: u32 = 0,
    /// The glyph atlas filled up: it starts over next frame.
    glyph_full: bool = false,
    /// Atlas pixels of the masks this frame draws.
    glyph_used: u64 = 0,
    /// New masks this frame may still rasterise.
    glyph_left: u32 = 0,
    glyph_uploads: std.ArrayList(GlyphUpload) = .empty,
    /// The new masks' bytes (uploads hold offsets here until `finish`).
    glyph_bytes: std.ArrayList(u8) = .empty,
    glyph_draws: std.ArrayList(GlyphDraw) = .empty,
    glyph_rects: std.ArrayList(GlyphRect) = .empty,
    /// A style's glyphs this frame: their keys, origins and masks when cached.
    glyph_picks: std.ArrayList(GlyphPick) = .empty,
    glyph_path: Path = .{},
    glyph_polys: Polylines = .{},
    /// Glyph outlines read once each (a page of small text draws hundreds of thousands
    /// of masks of a few thousand glyphs).
    outlines: font_mod.OutlineCache = .{},
    /// Scratch for rasterising one glyph mask (emptied after each).
    glyph_scratch: ?std.heap.ArenaAllocator = null,
    header: Header = .{},
    polys: Polylines = .{},
    clipped: std.ArrayList(Vec2) = .empty,
    clip_tmp: std.ArrayList(Vec2) = .empty,

    // The walk.
    sess: *Session = undefined,
    ox: i32 = 0,
    oy: i32 = 0,
    /// The viewport in the current top space.
    view: IRect = .{},
    shelf_x: u32 = 0,
    shelf_y: u32 = 0,
    shelf_h: u32 = 0,

    /// Building an item of records (`buildItem`).
    in_item: bool = false,
    /// An item of records (`records.Item`): only this node's drop shadows are drawn.
    only_shadows: ?*const m.Node = null,
    /// An item of records: this node's background blurs are left out (they read what lies
    /// under it, which an item drawn alone does not have).
    skip_backdrop: ?*const m.Node = null,

    pub fn init(gpa: Allocator) Scene {
        return .{
            .gpa = gpa,
        };
    }

    pub fn deinit(self: *Scene) void {
        self.forget();
        self.paths.deinit(self.gpa);
        self.texts.deinit(self.gpa);
        self.glyphs.deinit(self.gpa);
        self.glyph_uploads.deinit(self.gpa);
        self.glyph_bytes.deinit(self.gpa);
        self.glyph_draws.deinit(self.gpa);
        self.glyph_rects.deinit(self.gpa);
        self.glyph_picks.deinit(self.gpa);
        self.glyph_path.deinit(self.gpa);
        self.glyph_polys.deinit(self.gpa);
        self.outlines.deinit(self.gpa);
        if (self.glyph_scratch) |*a| a.deinit();
        self.backdrop.deinit(self.gpa);
        self.dev.deinit(self.gpa);
        self.recent.deinit(self.gpa);
        self.prims.deinit(self.gpa);
        self.shapes.deinit(self.gpa);
        self.shape_bounds.deinit(self.gpa);
        self.shape_cells.deinit(self.gpa);
        self.paints.deinit(self.gpa);
        self.stops.deinit(self.gpa);
        self.draws.deinit(self.gpa);
        self.entries.deinit(self.gpa);
        self.layers.deinit(self.gpa);
        self.verts.deinit(self.gpa);
        self.textures.deinit(self.gpa);
        self.texture_hashes.deinit(self.gpa);
        self.texture_first.deinit(self.gpa);
        self.fallbacks.deinit(self.gpa);
        self.fallback_ids.deinit(self.gpa);
        self.fallback_revs.deinit(self.gpa);
        self.surfaces.deinit(self.gpa);
        self.passes.deinit(self.gpa);
        self.open.deinit(self.gpa);
        self.texture_of.deinit(self.gpa);
        self.polys.deinit(self.gpa);
        self.clipped.deinit(self.gpa);
        self.clip_tmp.deinit(self.gpa);
    }

    /// Drops the paths kept between frames (the document changed or closed).
    pub fn forget(self: *Scene) void {
        var it = self.paths.valueIterator();
        while (it.next()) |c| c.path.deinit(self.gpa);
        self.paths.clearRetainingCapacity();
        var ti = self.texts.valueIterator();
        while (ti.next()) |tc| freeText(self.gpa, tc);
        self.texts.clearRetainingCapacity();
        self.glyphs.clearRetainingCapacity();
        self.outlines.clear(self.gpa);
        self.glyph_x = 0;
        self.glyph_y = 0;
        self.glyph_h = 0;
        self.backdrop.clearRetainingCapacity();
        var di = self.dev.valueIterator();
        while (di.next()) |d| d.polys.deinit(self.gpa);
        self.dev.clearRetainingCapacity();
        self.recent.clearRetainingCapacity();
    }

    /// Drops polylines the last few frames did not use.
    fn sweep(self: *Scene) void {
        if (self.dev.count() == 0) return;
        var it = self.dev.iterator();
        var stale: std.ArrayList(DevKey) = .empty;
        defer stale.deinit(self.gpa);
        while (it.next()) |e| {
            if (e.value_ptr.stamp + 2 < self.stamp) stale.append(self.gpa, e.key_ptr.*) catch return;
        }
        for (stale.items) |k| {
            if (self.dev.fetchRemove(k)) |kv| {
                var d = kv.value;
                d.polys.deinit(self.gpa);
            }
        }
        // Removals leave tombstones that lengthen every lookup: sweep them out.
        if (stale.items.len > 0) self.dev.rehash(std.hash_map.AutoContext(DevKey){});
    }

    /// The cached polylines for `part` of `n` under `ctm`; `fresh` when the caller must
    /// fill them (then call `sealed`).
    fn devPolys(self: *Scene, n: *const m.Node, part: u32, ctm: Affine) !struct {
        d: *DevPolys,
        fresh: bool,
    } {
        const key: DevKey = .{
            .node = @intFromPtr(n),
            .part = part,
            .ctm = .{ @bitCast(ctm.a), @bitCast(ctm.b), @bitCast(ctm.c), @bitCast(ctm.d), @bitCast(ctm.e), @bitCast(ctm.f) },
        };
        const pk: PathKey = .{
            .node = key.node,
            .part = part,
        };
        const got = try self.dev.getOrPut(self.gpa, key);
        if (got.found_existing and got.value_ptr.approx and !self.motion) {
            // A stand-in from moving: the exact ones now.
            got.value_ptr.polys.clear();
            got.value_ptr.approx = false;
            got.value_ptr.stamp = self.stamp;
            try self.recent.put(self.gpa, pk, key);
            return .{
                .d = got.value_ptr,
                .fresh = true,
            };
        }
        if (!got.found_existing) {
            got.value_ptr.* = .{
                .polys = .{},
                .bounds = .empty,
                .winding = .nonzero,
                .stamp = self.stamp,
            };
            if (self.motion) if (self.recent.get(pk)) |rk| if (self.dev.getPtr(rk)) |src| {
                if (standIn(src, rk.ctm, ctm)) |mv| {
                    // The polylines of a nearby scale, moved here.
                    const d = got.value_ptr;
                    try d.polys.points.ensureTotalCapacity(self.gpa, src.polys.points.items.len);
                    for (src.polys.points.items) |pt| d.polys.points.appendAssumeCapacity(mv.apply(pt));
                    try d.polys.contours.appendSlice(self.gpa, src.polys.contours.items);
                    d.winding = src.winding;
                    d.op = src.op;
                    d.has_fill = src.has_fill;
                    d.approx = true;
                    seal(d);
                    return .{
                        .d = d,
                        .fresh = false,
                    };
                }
            };
            try self.recent.put(self.gpa, pk, key);
        }
        got.value_ptr.stamp = self.stamp;
        return .{
            .d = got.value_ptr,
            .fresh = !got.found_existing,
        };
    }

    /// Drops what is kept of nodes an edit changed, moved or removed (and of the
    /// subtrees that hold them), as the session's editor names them.
    fn dropEdited(self: *Scene, sess: *Session) void {
        const fg = sess.edit.takeForgotten();
        defer sess.edit.clearForgotten();
        if (fg.nodes.len == 0 and fg.trees.len == 0) return;
        var gone: std.AutoHashMapUnmanaged(usize, void) = .empty;
        defer gone.deinit(self.gpa);
        for (fg.nodes) |p| gone.put(self.gpa, p, {}) catch return self.forget();
        for (fg.nodes) |p| {
            if (self.texts.fetchRemove(p)) |kv| {
                var tc = kv.value;
                freeText(self.gpa, &tc);
            }
            _ = self.backdrop.remove(p);
        }
        for (fg.trees) |p| _ = self.backdrop.remove(p);
        var stale: std.ArrayList(PathKey) = .empty;
        defer stale.deinit(self.gpa);
        var pi = self.paths.keyIterator();
        while (pi.next()) |k| if (gone.contains(k.node)) stale.append(self.gpa, k.*) catch return self.forget();
        for (stale.items) |k| if (self.paths.fetchRemove(k)) |kv| {
            var c = kv.value;
            c.path.deinit(self.gpa);
        };
        stale.clearRetainingCapacity();
        var ri = self.recent.keyIterator();
        while (ri.next()) |k| if (gone.contains(k.node)) stale.append(self.gpa, k.*) catch return self.forget();
        for (stale.items) |k| _ = self.recent.remove(k);
        var dead: std.ArrayList(DevKey) = .empty;
        defer dead.deinit(self.gpa);
        var di = self.dev.keyIterator();
        while (di.next()) |k| if (gone.contains(k.node)) dead.append(self.gpa, k.*) catch return self.forget();
        for (dead.items) |k| if (self.dev.fetchRemove(k)) |kv| {
            var d = kv.value;
            d.polys.deinit(self.gpa);
        };
    }

    fn reset(self: *Scene, sess: *Session) void {
        self.sess = sess;
        self.dropEdited(sess);
        // A new frame: images it does not draw may give their memory back. An item of
        // records belongs to the records' frame: the images that frame wants stay wanted.
        if (!self.in_item) sess.beginPass();
        self.stamp += 1;
        self.prims.clearRetainingCapacity();
        self.shapes.clearRetainingCapacity();
        self.shape_bounds.clearRetainingCapacity();
        self.shape_cells.clearRetainingCapacity();
        self.paints.clearRetainingCapacity();
        self.stops.clearRetainingCapacity();
        self.draws.clearRetainingCapacity();
        self.entries.clearRetainingCapacity();
        self.layers.clearRetainingCapacity();
        self.verts.clearRetainingCapacity();
        self.textures.clearRetainingCapacity();
        self.texture_hashes.clearRetainingCapacity();
        self.texture_first.clearRetainingCapacity();
        self.fallbacks.clearRetainingCapacity();
        self.fallback_ids.clearRetainingCapacity();
        self.fallback_revs.clearRetainingCapacity();
        self.surfaces.clearRetainingCapacity();
        self.passes.clearRetainingCapacity();
        self.open.clearRetainingCapacity();
        self.opaque_of = null;
        self.texture_of.clearRetainingCapacity();
        self.header = .{};
        self.shelf_x = 0;
        self.shelf_y = 0;
        self.shelf_h = 0;
        self.glyph_uploads.clearRetainingCapacity();
        self.glyph_bytes.clearRetainingCapacity();
        self.glyph_draws.clearRetainingCapacity();
        self.glyph_left = glyph_budget;
        // A full atlas starts over when the last frame used under 70% of it (the rest is
        // other views' masks); when the view needs that much, it stays as it is and text
        // without masks draws as paths.
        const area: u64 = @as(u64, glyph_atlas_size) * glyph_atlas_size;
        if (self.glyph_full and self.glyph_used * 10 < area * 7) {
            self.glyphs.clearRetainingCapacity();
            self.glyph_x = 0;
            self.glyph_y = 0;
            self.glyph_h = 0;
            self.glyph_full = false;
        }
        self.glyph_used = 0;
        _ = sess.renderer.frame.reset(.retain_capacity);
    }

    /// The frame for `w` x `h` device pixels of page `page_index` with world (`x`, `y`) at
    /// the top left and `scale` device pixels per unit.
    pub fn buildPage(self: *Scene, sess: *Session, page_index: usize, x: f64, y: f64, scale: f32, w: u32, h: u32) !void {
        self.reset(sess);
        const pages = sess.pages();
        if (page_index >= pages.len) return error.NoSuchPage;
        const screen: IRect = .{
            .x1 = @intCast(w),
            .y1 = @intCast(h),
        };
        // The view's corner on the whole device pixel at or nearest (`x`, `y`): a node's
        // fraction of a pixel then depends on it alone, so panning keeps every number.
        const sd: f64 = scale;
        const vx = @round(x * sd);
        const vy = @round(y * sd);
        // A background blur reads past the view's edge: the target holds that much more
        // around it, as a CPU tile does (`Session.renderTile`).
        var margin: f32 = 0;
        for (pages[page_index].children) |*c| {
            const at = placeAt(c, vx, vy, scale);
            margin = @max(margin, session_mod.backdropReach(c, at.ctm, at.shift(screen)));
        }
        const apron: i32 = @intFromFloat(@ceil(@min(margin, max_apron)));
        self.header.apron = @intCast(apron);
        const view = screen.outset(apron);
        for (pages[page_index].children) |*c| {
            const at = placeAt(c, vx, vy, scale);
            self.ox = at.dx + apron;
            self.oy = at.dy + apron;
            self.view = at.shift(view);
            try self.top(c, at.ctm);
        }
        self.finish();
    }

    /// The frame of node `id` the way an export draws it: its box at `scale`, top left at
    /// 0, 0, `w` x `h` device pixels.
    pub fn buildNode(self: *Scene, sess: *Session, id: []const u8, scale: f32, w: u32, h: u32) !void {
        self.reset(sess);
        const n = sess.findNode(id) orelse return error.NoSuchNode;
        self.ox = 0;
        self.oy = 0;
        self.view = .{
            .x1 = @intCast(w),
            .y1 = @intCast(h),
        };
        try self.top(n, Affine.scaling(scale, scale));
        self.finish();
    }

    /// An item of records (`records.Item`): part of node `n` under `ctm` (top space) into
    /// `rect` (top space), on its own (a transparent target, unclipped).
    pub fn buildItem(self: *Scene, sess: *Session, n: *const m.Node, kind: u32, child: u32, ctm: Affine, rect: IRect) !void {
        self.in_item = true;
        defer self.in_item = false;
        self.reset(sess);
        self.ox = -rect.x0;
        self.oy = -rect.y0;
        self.view = rect;
        self.only_shadows = null;
        self.skip_backdrop = null;
        defer {
            self.only_shadows = null;
            self.skip_backdrop = null;
        }
        switch (kind) {
            1 => {
                self.skip_backdrop = n;
                try self.node(n, ctm, none);
            },
            2 => {
                self.only_shadows = n;
                try self.isolated(n, ctm, none);
            },
            3 => {
                const fill = try self.fillOf(n, ctm);
                if (fill == .formula or fill == .path) for (n.effects, 0..) |e, ei| {
                    if (e.visible and e.kind == .inner_shadow) try self.innerShadow(n, e, @intCast(ei), ctm, none, fill);
                };
            },
            6 => try self.node(n, ctm, none),
            5 => {
                // What lies under the node blurred, read from the target (offsets: top
                // space to the target is `-rect` origin's opposite, the frame's).
                for (n.effects, 0..) |e, ei| {
                    if (e.visible and e.kind == .background_blur) {
                        try self.backgroundBlur(n, e, @intCast(ei), ctm, none);
                        break;
                    }
                }
            },
            4 => {
                const kids = n.children;
                const i: usize = child;
                var j = i + 1;
                while (j < kids.len and kids[j].mask == null) j += 1;
                if (i < kids.len and j > i + 1) try self.maskRun(n, i, j, ctm, none, rect);
            },
            else => {},
        }
        self.finish();
    }

    fn finish(self: *Scene) void {
        self.sweep();
        self.closeLayer();
        // In WASM an upload points at its bytes; a native host (64-bit addresses) reads the
        // offset into `glyph_bytes` the walk left there.
        if (@sizeOf(usize) == 4) for (self.glyph_uploads.items) |*u| {
            u.ptr = addr(self.glyph_bytes.items.ptr + u.ptr);
        };
        const h = &self.header;
        h.prims = addr(self.prims.items.ptr);
        h.prim_count = @intCast(self.prims.items.len);
        h.shapes = addr(self.shapes.items.ptr);
        h.shape_count = @intCast(self.shapes.items.len);
        h.paints = addr(self.paints.items.ptr);
        h.paint_count = @intCast(self.paints.items.len);
        h.stops = addr(self.stops.items.ptr);
        h.stop_count = @intCast(self.stops.items.len);
        h.draws = addr(self.draws.items.ptr);
        h.draw_count = @intCast(self.draws.items.len);
        h.entries = addr(self.entries.items.ptr);
        h.entry_count = @intCast(self.entries.items.len);
        h.layers = addr(self.layers.items.ptr);
        h.layer_count = @intCast(self.layers.items.len);
        h.verts = addr(self.verts.items.ptr);
        h.vert_count = @intCast(self.verts.items.len);
        h.textures = addr(self.textures.items.ptr);
        h.texture_count = @intCast(self.textures.items.len);
        h.fallbacks = addr(self.fallbacks.items.ptr);
        h.fallback_count = @intCast(self.fallbacks.items.len);
        h.glyph_uploads = addr(self.glyph_uploads.items.ptr);
        h.glyph_upload_count = @intCast(self.glyph_uploads.items.len);
        h.glyph_draws = addr(self.glyph_draws.items.ptr);
        h.glyph_draw_count = @intCast(self.glyph_draws.items.len);
        h.glyphs_cached = self.glyphs.count();
        h.surfaces = addr(self.surfaces.items.ptr);
        h.surface_count = @intCast(self.surfaces.items.len);
        h.passes = addr(self.passes.items.ptr);
        h.pass_count = @intCast(self.passes.items.len);
    }

    /// Ends the last atlas layer's ranges.
    fn closeLayer(self: *Scene) void {
        if (self.layers.items.len == 0) return;
        const last = &self.layers.items[self.layers.items.len - 1];
        last.vert_count = @as(u32, @intCast(self.verts.items.len)) - last.vert_first;
        last.entry_count = @as(u32, @intCast(self.entries.items.len)) - last.entry_first;
        last.glyph_count = @as(u32, @intCast(self.glyph_draws.items.len)) - last.glyph_first;
    }

    /// Level `level` of texture `index` (premultiplied RGBA8 except level 0, which is
    /// straight), with its size.
    pub fn textureLevel(self: *const Scene, index: u32, level: u32) ?pix.Mipmap.Level {
        if (index >= self.texture_hashes.items.len) return null;
        const mip = self.sess.images.getPtr(self.texture_hashes.items[index]) orelse return null;
        // Level `level` of the chain the texture was taken from, in the chain held now.
        const abs = @as(u32, self.texture_first.items[index]) + level;
        if (abs < mip.first) return null;
        const at = abs - mip.first;
        if (at >= mip.levels.len) return null;
        return mip.levels[at];
    }

    // ------------------------------------------------------------------ the walk

    /// A node drawn onto the page (or exported).
    fn top(self: *Scene, n: *const m.Node, ctm: Affine) !void {
        try self.node(n, ctm, none);
    }

    fn readsBackdrop(self: *Scene, n: *const m.Node) !bool {
        if (self.backdrop.get(@intFromPtr(n))) |v| return v;
        var v = false;
        if (n.visible) {
            if (n.blend != .pass_through and n.blend != .normal) v = true;
            for ([2][]const m.Paint{ n.fills, n.strokes }) |ps| for (ps) |p| {
                if (p.visible and p.blend != .normal) v = true;
            };
            for (n.geometry) |g| if (g.fills) |fs| for (fs) |p| {
                if (p.visible and p.blend != .normal) v = true;
            };
            for (n.effects) |e| {
                if (e.visible and e.kind == .background_blur) v = true;
            }
            for (n.children) |*c| {
                if (try self.readsBackdrop(c)) v = true;
            }
        }
        try self.backdrop.put(self.gpa, @intFromPtr(n), v);
        return v;
    }

    /// Whether a child of `n` reads what lies under it.
    fn kidsReadBackdrop(self: *Scene, n: *const m.Node) !bool {
        for (n.children) |*c| if (try self.readsBackdrop(c)) return true;
        return false;
    }

    /// Mirrors `Renderer.drawNode`.
    fn node(self: *Scene, n: *const m.Node, ctm: Affine, clip: u32) anyerror!void {
        if (!n.visible or n.opacity <= 0 or n.kind == .slice) return;
        var reach = IRect.around(render.cullBounds(n, ctm)).intersect(self.view);
        if (clip != none) reach = reach.intersect(self.shape_bounds.items[clip]);
        if (reach.isEmpty()) {
            self.header.culled += 1;
            return;
        }
        self.header.nodes += 1;
        // Glyph origins snapped to a device grid (a tool's setting) come from the CPU.
        if (n.kind == .text and render.glyph_x_bins > 0) return self.fallback(n, ctm, clip, .whole, 0, .text, reach);
        // Text without fonts draws nothing at all (not even its effects).
        if (n.kind == .text and (self.sess.renderer.fonts == null or n.text == null)) return;
        const extent = render.effectExtent(n, ctm);
        const isolate = n.opacity < 1 or extent > 0 or (n.blend != .pass_through and n.blend != .normal);
        if (!isolate) return self.content(n, ctm, clip, 1);
        // A see-through node with one paint and nothing else: its opacity goes on the paint
        // (the layer the CPU draws holds that paint alone).
        if (extent == 0 and (n.blend == .pass_through or n.blend == .normal) and n.children.len == 0 and !paintsBlend(n) and paintCount(n) <= 1) {
            return self.content(n, ctm, clip, n.opacity);
        }
        // Blurred as a whole wider than `coarse_sigma`: drawn whole on the coarse grid.
        var whole: f32 = 0;
        for (n.effects) |e| {
            if (e.visible and e.kind == .layer_blur) whole = @max(whole, efx.blurReach(e) * ctm.maxScale() * render.layer_blur_k);
        }
        if (render.Coarse.of(ctm, whole)) |c| return self.coarseNode(n, ctm, clip, c);
        return self.isolated(n, ctm, clip);
    }

    /// Mirrors `Renderer.drawIsolated`: background blurs onto the target, the content in a
    /// surface of its own (or straight onto the target when that comes to the same),
    /// its noise, texture and blur, the drop shadows cast from it, then the surface
    /// composited with the node's opacity and blend mode.
    fn isolated(self: *Scene, n: *const m.Node, ctm: Affine, clip: u32) !void {
        const dst = self.view;
        const only = self.only_shadows == n;
        if (!only and self.skip_backdrop != n) for (n.effects, 0..) |e, ei| {
            if (e.visible and e.kind == .background_blur) try self.backgroundBlur(n, e, @intCast(ei), ctm, clip);
        };
        const by_shape = render.shapeSilhouette(n);
        const extent = if (by_shape) render.layerExtent(n, ctm) else render.fineExtent(n, ctm);
        const reach_out: i32 = @intFromFloat(@ceil(extent));
        var content_rect = IRect.around(render.visualBounds(n, ctm)).intersect(dst.outset(reach_out));
        var layer_blur: f32 = 0;
        var layer_fx = false;
        for (n.effects) |e| {
            if (!e.visible) continue;
            switch (e.kind) {
                .layer_blur => {
                    layer_blur = @max(layer_blur, efx.blurReach(e) * ctm.maxScale() * render.layer_blur_k);
                    layer_fx = true;
                },
                .noise, .texture => layer_fx = true,
                else => {},
            }
        }
        const room = @max(layer_blur * 3, efx.textureRoom(n, ctm));
        if (room > 0) content_rect = content_rect.outset(@intFromFloat(@ceil(room))).intersect(dst.outset(reach_out));

        const blend = render.blendMode(n.blend);
        // The content straight onto the target composites the same as its surface would.
        const direct = n.opacity >= 1 and blend == .normal and !layer_fx and !paintsBlend(n) and !(try self.kidsReadBackdrop(n));
        var need_layer = !direct;
        for (n.effects) |e| {
            if (!e.visible or e.kind != .drop_shadow) continue;
            if (self.shadowFormula(n, ctm) != null) continue;
            if (render.Coarse.of(ctm, e.radius * ctm.maxScale() * render.shadow_k) != null) continue;
            if (!by_shape) need_layer = true;
        }
        var layer: ?u32 = null;
        if (need_layer and !content_rect.isEmpty()) {
            const sv = try self.beginSurface(content_rect, n, part_content, 0, ctm);
            try self.content(n, ctm, none, 1);
            for (n.effects) |e| {
                if (!e.visible) continue;
                if (e.kind == .noise) try self.noisePass(sv.surface, e, ctm);
                if (e.kind == .texture) try self.texturePass(n, sv.surface, e, ctm);
            }
            for (n.effects) |e| {
                if (!e.visible or e.kind != .layer_blur) continue;
                if (e.progressive != null) {
                    try self.progressivePass(sv.surface, n, e, ctm, render.layer_blur_k);
                } else {
                    try self.blurPass(sv.surface, e.radius * ctm.maxScale() * render.layer_blur_k, .layer);
                }
                break;
            }
            layer = sv.surface;
            try self.endSurface(sv);
        }

        // Shadows are cast as if see-through paints were opaque.
        var silhouette: ?u32 = null;
        for (n.effects, 0..) |e, ei| {
            if (!e.visible or e.kind != .drop_shadow) continue;
            if (self.shadowFormula(n, ctm)) |f| {
                try self.formulaShadow(n, e, ctm, clip, f);
                continue;
            }
            if (render.Coarse.of(ctm, e.radius * ctm.maxScale() * render.shadow_k)) |c| {
                try self.coarseShadow(n, e, @intCast(ei), ctm, clip, c);
                continue;
            }
            if (by_shape) {
                try self.dropShadow(n, e, @intCast(ei), ctm, clip, .shape, n.opacity);
                continue;
            }
            const l = layer orelse continue;
            if (silhouette == null) {
                silhouette = l;
                if (efx.hasTranslucentPaint(n)) {
                    const sv = try self.beginSurface(self.surfaceRect(l), n, part_opaque, 0, ctm);
                    self.opaque_of = n;
                    defer self.opaque_of = null;
                    try self.content(n, ctm, none, 1);
                    silhouette = sv.surface;
                    try self.endSurface(sv);
                }
            }
            try self.dropShadow(n, e, @intCast(ei), ctm, clip, .{
                .surface = silhouette.?,
            }, n.opacity);
        }
        if (only) return;
        if (layer) |l| {
            const r = self.surfaceRect(l);
            try self.composite(r.intersect(dst), clip, try self.surfacePaint(l, translation(-r.x0, -r.y0), .{}), n.opacity, Blend.of(blend), .layer);
        } else if (direct) {
            try self.content(n, ctm, clip, 1);
        }
    }

    /// `Renderer.drawCoarse`: the node whole on a coarse grid, scaled up onto the target.
    fn coarseNode(self: *Scene, n: *const m.Node, ctm: Affine, clip: u32, c: render.Coarse) !void {
        const lo_ctm = c.ctmFor(ctm);
        const rect = c.rectFor(self.view).outset(2);
        const sv = try self.beginSurface(rect, n, part_coarse, 0, lo_ctm);
        try self.isolated(n, lo_ctm, none);
        try self.endSurface(sv);
        try self.coarseComposite(sv.surface, c, clip);
    }

    /// Surface `s` drawn on the coarse grid `c` onto the target, bilinear
    /// (`Coarse.drawScaledUp`).
    fn coarseComposite(self: *Scene, s: u32, c: render.Coarse, clip: u32) !void {
        const r = self.surfaceRect(s);
        // Top space to the surface's texels: (q - a) / k - x0.
        const inv: Affine = .{
            .a = 1 / c.k,
            .d = 1 / c.k,
            .e = -c.ax / c.k - @as(f32, @floatFromInt(r.x0)),
            .f = -c.ay / c.k - @as(f32, @floatFromInt(r.y0)),
        };
        const back = IRect.around(.{
            .x0 = @as(f32, @floatFromInt(r.x0)) * c.k + c.ax,
            .y0 = @as(f32, @floatFromInt(r.y0)) * c.k + c.ay,
            .x1 = @as(f32, @floatFromInt(r.x1)) * c.k + c.ax,
            .y1 = @as(f32, @floatFromInt(r.y1)) * c.k + c.ay,
        });
        try self.composite(back.intersect(self.view), clip, try self.surfacePaint(s, inv, .{
            .filtered = true,
        }), 1, .normal, .layer);
    }

    /// Mirrors `Renderer.drawContent`.
    fn content(self: *Scene, n: *const m.Node, ctm: Affine, clip: u32, opacity: f32) anyerror!void {
        const fill = try self.fillOf(n, ctm);
        const clips = n.clip and n.children.len > 0 and fill != .none;
        const fills = try self.ownPaints(n, n.fills);

        const regions = render.use_geometry and hasRegionFills(n);
        if (regions) for (n.geometry, 0..) |g, gi| {
            const ch = try self.pathChunks(n, @intCast(gi + 1), ctm);
            for (g.fills orelse fills) |*p| {
                if (!p.visible) continue;
                if (p.kind == .pattern) continue;
                const paint = try self.paintFor(p, n.size, ctm) orelse continue;
                var k: u32 = 0;
                while (k < ch.count) : (k += 1) try self.addPrimBlend(ch.first + k, clip, paint, opacity * p.opacity, .fill_path, p.blend);
            }
        };

        if (!regions and (fill == .formula or fill == .path)) for (fills) |*p| {
            if (!p.visible) continue;
            if (p.kind == .pattern) {
                try self.patternPaint(n, p, .{
                    .x1 = n.size.x,
                    .y1 = n.size.y,
                }, ctm, clip, fill, null, opacity);
                continue;
            }
            const paint = try self.paintFor(p, n.size, ctm) orelse continue;
            switch (fill) {
                .none, .hidden => {},
                .formula => |s| try self.addPrimBlend(s, clip, paint, opacity * p.opacity, .fill_formula, p.blend),
                .path => |ch| {
                    var k: u32 = 0;
                    while (k < ch.count) : (k += 1) try self.addPrimBlend(ch.first + k, clip, paint, opacity * p.opacity, .fill_path, p.blend);
                },
            }
        };

        if (fill == .formula or fill == .path) for (n.effects, 0..) |e, ei| {
            if (e.visible and e.kind == .inner_shadow) try self.innerShadow(n, e, @intCast(ei), ctm, clip, fill);
        };

        if (n.kind == .text) try self.text(n, ctm, clip, opacity);

        // Children of a clip with nothing in view are clipped away.
        if (n.children.len > 0 and !(clips and fill == .hidden)) {
            if (clips) {
                const area = try self.fillArea(n, ctm, fill);
                switch (fill) {
                    .formula => |s| {
                        const saved = self.view;
                        self.view = self.view.intersect(area);
                        defer self.view = saved;
                        try self.children(n, ctm, try self.pushClip(s, clip));
                    },
                    // A path clip: one shape when it fits one atlas cell, else the
                    // children in a surface composited through the path's coverage.
                    .path => |ch| if (ch.count == 1) {
                        const saved = self.view;
                        self.view = self.view.intersect(area);
                        defer self.view = saved;
                        try self.children(n, ctm, try self.pushClip(ch.first, clip));
                    } else {
                        const rect = self.view.intersect(area);
                        if (!rect.isEmpty()) {
                            const sv = try self.beginSurface(rect, n, part_clip, 0, ctm);
                            try self.children(n, ctm, none);
                            try self.endSurface(sv);
                            const paint = try self.surfacePaint(sv.surface, translation(-rect.x0, -rect.y0), .{});
                            var k: u32 = 0;
                            while (k < ch.count) : (k += 1) try self.addPrimBlend(ch.first + k, clip, paint, 1, .layer, .normal);
                        }
                    },
                    .none, .hidden => unreachable,
                }
            } else try self.children(n, ctm, clip);
        }

        if (hasVisible(n.strokes) and n.stroke.weight > 0) try self.strokes(n, ctm, clip, opacity, fill);
    }

    /// The node's own paints, opaque while its silhouette is drawn (`opaque_of`).
    fn ownPaints(self: *Scene, n: *const m.Node, ps: []const m.Paint) ![]const m.Paint {
        if (self.opaque_of != n) return ps;
        return efx.opaquePaints(self.sess.renderer.frame.allocator(), ps);
    }

    /// The pixels the node's fill shape touches (top space): `rasterize`'s mask rect
    /// before its clip.
    fn fillArea(self: *Scene, n: *const m.Node, ctm: Affine, fill: Fill) !IRect {
        switch (fill) {
            .formula => return IRect.around(geom.Rect.transformed(.{
                .x1 = n.size.x,
                .y1 = n.size.y,
            }, ctm)),
            .path => {
                const dp = try self.devPolys(n, 0, ctm);
                return IRect.around(dp.d.bounds);
            },
            .none, .hidden => return .{},
        }
    }

    /// The widest apron a frame's target gets (`Session.max_apron`).
    const max_apron: f32 = 1024;

    /// Mirrors `Renderer.drawChildren`.
    fn children(self: *Scene, n: *const m.Node, ctm: Affine, clip: u32) anyerror!void {
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
                for (n.children) |*c| try self.node(c, ctm.mul(t).mul(c.transform), clip);
            }
            return;
        }
        const kids = n.children;
        if (n.reverse_z) {
            var k = kids.len;
            while (k > 0) {
                k -= 1;
                try self.node(&kids[k], ctm.mul(kids[k].transform), clip);
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
                    var reach: IRect = .{};
                    for (kids[i + 1 .. j]) |*k| reach = reach.unite(IRect.around(render.cullBounds(k, ctm.mul(k.transform))));
                    reach = reach.intersect(self.view);
                    if (clip != none) reach = reach.intersect(self.shape_bounds.items[clip]);
                    if (!reach.isEmpty()) try self.maskRun(n, i, j, ctm, clip, reach);
                }
                i = j;
            } else {
                try self.node(c, ctm.mul(c.transform), clip);
                i += 1;
            }
        }
    }

    /// Mirrors `Renderer.drawText`: each style's glyphs as one path in the atlas, filled
    /// with the style's paints.
    fn text(self: *Scene, n: *const m.Node, ctm: Affine, clip: u32, opacity: f32) !void {
        if (self.sess.renderer.fonts == null or n.text == null) return;
        const tc = try self.textOf(n) orelse return;
        for (tc.styles) |*tp| {
            // Text drawn as its source laid it out (a font is missing) is paths only.
            const glyphs = if (self.sess.renderer.usesFileGlyphs(n)) null else try self.styleGlyphs(&tc.lay, tp.style, ctm);
            // The glyph route keeps only the decorations as paths: its own polylines.
            const part = text_part + tp.style + if (glyphs != null) glyph_part else 0;
            const dp = try self.devPolys(n, part, ctm);
            var ch: Chunks = undefined;
            if (glyphs) |list| {
                // Glyph masks from the atlas, decorations as paths, summed in the entry.
                if (dp.fresh) {
                    self.glyph_path.verbs.clearRetainingCapacity();
                    self.glyph_path.points.clearRetainingCapacity();
                    for (tc.lay.decorations.items) |d| {
                        if (d.style == tp.style) try render.addDecoration(self.gpa, d.rect, &self.glyph_path);
                    }
                    try render.devicePolys(self.gpa, &self.glyph_path, ctm, &dp.d.polys);
                    seal(dp.d);
                }
                var b = dp.d.bounds;
                for (list) |g| b = b.unite(.{
                    .x0 = @floatFromInt(g.rect.x0),
                    .y0 = @floatFromInt(g.rect.y0),
                    .x1 = @floatFromInt(g.rect.x1),
                    .y1 = @floatFromInt(g.rect.y1),
                });
                ch = try self.chunksWith(dp.d, b, list);
            } else {
                if (dp.fresh) {
                    try render.devicePolys(self.gpa, &tp.path, ctm, &dp.d.polys);
                    seal(dp.d);
                }
                ch = try self.chunksOf(dp.d);
            }
            if (ch.count == 0) continue;
            // The silhouette's text: the node's own paints opaque, a run's as they are.
            const fills = if (self.opaque_of == n and tp.fills.ptr == n.fills.ptr) try self.ownPaints(n, tp.fills) else tp.fills;
            for (fills) |*p| {
                if (!p.visible) continue;
                const paint = try self.paintFor(p, n.size, ctm) orelse continue;
                var k: u32 = 0;
                while (k < ch.count) : (k += 1) try self.addPrim(ch.first + k, none, .none, clip, paint, opacity * p.opacity, .text);
            }
        }
    }

    /// The node's layout and style paths, made once.
    fn textOf(self: *Scene, n: *const m.Node) !?*TextCache {
        if (self.texts.getPtr(@intFromPtr(n))) |tc| return tc;
        const r = &self.sess.renderer;
        var lay = try r.textLayout(n) orelse return null;
        errdefer lay.deinit(self.gpa);
        var list: std.ArrayList(render.TextPath) = .empty;
        errdefer {
            for (list.items) |*tp| tp.path.deinit(self.gpa);
            list.deinit(self.gpa);
        }
        try r.stylePaths(n, &lay, &list);
        const styles = try list.toOwnedSlice(self.gpa);
        errdefer self.gpa.free(styles);
        try self.texts.put(self.gpa, @intFromPtr(n), .{
            .lay = lay,
            .styles = styles,
        });
        return self.texts.getPtr(@intFromPtr(n)).?;
    }

    /// Style `style`'s glyphs as masks from the glyph atlas (rasterised there when new),
    /// or null when they are drawn as paths: turned, too large, or the atlas is full.
    fn styleGlyphs(self: *Scene, lay: *const text_layout.Layout, style: u32, ctm: Affine) !?[]const GlyphRect {
        const pattern: mask_mod.Pattern = switch (render.text_aa) {
            .figma16 => &mask_mod.figma16,
            .grid16 => &mask_mod.grid16,
            .standard16 => &mask_mod.standard16,
            .custom => render.custom_pattern,
            .exact => return null,
        };
        if (!(ctm.b == 0 and ctm.c == 0 and ctm.a == ctm.d and ctm.a > 0)) return null;
        // While the view moves, text is paths: every glyph of a run at the frame's own
        // scale, so text scales smoothly. (Masks of nearby scales, picked glyph by
        // glyph, drew a run at mixed sizes and jumped from one scale to the next.)
        if (self.motion) return null;
        // Within the budget, or paths this frame.
        var new: u32 = 0;
        self.glyph_picks.clearRetainingCapacity();
        for (lay.glyphs.items) |g| {
            if (g.style != style) continue;
            if (g.cos != 1 or g.sin != 0 or g.size * ctm.a > glyph_max_em) return null;
            const d = ctm.apply(.{
                .x = g.x,
                .y = g.y,
            });
            // Glyphs far from the view need no mask (and count against no budget).
            if (@abs(d.x) > 1e7 or @abs(d.y) > 1e7) return null;
            const reach = @ceil(g.size * ctm.a * 3 + 4);
            const vx0: f32 = @floatFromInt(self.view.x0);
            const vy0: f32 = @floatFromInt(self.view.y0);
            const vx1: f32 = @floatFromInt(self.view.x1);
            const vy1: f32 = @floatFromInt(self.view.y1);
            if (@floor(d.x) + reach < vx0 or @floor(d.y) + reach < vy0 or @floor(d.x) - reach > vx1 or @floor(d.y) - reach > vy1) continue;
            const key = glyphKey(g, ctm, d);
            const slot = self.glyphs.get(key);
            if (slot == null) new += 1;
            try self.glyph_picks.append(self.gpa, .{
                .g = g,
                .key = key,
                .d = d,
                .slot = slot,
            });
        }
        // Over what is left of the frame's budget: paths now, masks next frame. A style
        // needing more than a whole budget takes it whole when it comes first (else it
        // would wait for ever).
        // A full atlas takes no new masks until it starts over: paths, and no deferral.
        if (new > 0 and self.glyph_full) return null;
        if (new > self.glyph_left and !(self.glyph_left == glyph_budget and glyph_budget > 0)) {
            self.header.glyphs_deferred += 1;
            return null;
        }
        self.glyph_left -|= new;
        self.glyph_rects.clearRetainingCapacity();
        for (self.glyph_picks.items) |pick| {
            const g = pick.g;
            const d = pick.d;
            const bx = @floor(d.x);
            const by = @floor(d.y);
            const ix: i32 = @intFromFloat(bx);
            const iy: i32 = @intFromFloat(by);
            const slot = pick.slot orelse try self.glyphSlot(g, ctm, bx, by, pick.key, pattern) orelse return null;
            if (slot.w == 0) continue;
            self.glyph_used += (slot.w + 1) * (slot.h + 1);
            try self.glyph_rects.append(self.gpa, .{
                .rect = .{
                    .x0 = ix + slot.ox,
                    .y0 = iy + slot.oy,
                    .x1 = ix + slot.ox + @as(i32, @intCast(slot.w)),
                    .y1 = iy + slot.oy + @as(i32, @intCast(slot.h)),
                },
                .sx = slot.x,
                .sy = slot.y,
            });
        }
        return self.glyph_rects.items;
    }

    /// The glyph's mask: the CPU's coverage of its outline (the same points, moved by
    /// whole pixels), in the glyph atlas. Null when the atlas is full.
    fn glyphSlot(self: *Scene, g: text_layout.Placed, ctm: Affine, bx: f32, by: f32, key: GlyphKey, pattern: mask_mod.Pattern) !?GlyphSlot {
        const gm = render.glyphTransform(g);
        if (self.glyphs.get(key)) |slot| return slot;
        if (self.glyph_full) return null;
        self.glyph_path.verbs.clearRetainingCapacity();
        self.glyph_path.points.clearRetainingCapacity();
        try self.outlines.outline(self.gpa, g.font, g.glyph, gm, &self.glyph_path);
        self.glyph_polys.clear();
        try render.devicePolys(self.gpa, &self.glyph_path, ctm, &self.glyph_polys);
        var b: geom.Rect = .empty;
        for (self.glyph_polys.points.items) |*p| {
            p.* = .{
                .x = p.x - bx,
                .y = p.y - by,
            };
            b.include(p.*);
        }
        const rect = IRect.around(b);
        var slot: GlyphSlot = .{
            .x = 0,
            .y = 0,
            .w = 0,
            .h = 0,
            .ox = 0,
            .oy = 0,
        };
        if (!rect.isEmpty()) {
            if (self.glyph_scratch == null) self.glyph_scratch = .init(self.gpa);
            const scratch = &self.glyph_scratch.?;
            defer _ = scratch.reset(.retain_capacity);
            const mk = try mask_mod.fillSampled(scratch.allocator(), &self.glyph_polys, .nonzero, rect, pattern);
            const w = mk.rect.width();
            const h = mk.rect.height();
            if (w > 0 and h > 0) {
                if (self.glyph_x + w + 1 > glyph_atlas_size) {
                    self.glyph_x = 0;
                    self.glyph_y += self.glyph_h;
                    self.glyph_h = 0;
                }
                if (self.glyph_y + h + 1 > glyph_atlas_size or w + 1 > glyph_atlas_size) {
                    self.glyph_full = true;
                    return null;
                }
                slot = .{
                    .x = self.glyph_x,
                    .y = self.glyph_y,
                    .w = w,
                    .h = h,
                    .ox = mk.rect.x0,
                    .oy = mk.rect.y0,
                };
                self.glyph_x += w + 1;
                self.glyph_h = @max(self.glyph_h, h + 1);
                const at: u32 = @intCast(self.glyph_bytes.items.len);
                for (mk.data) |v| try self.glyph_bytes.append(self.gpa, @intFromFloat(@round(std.math.clamp(v, 0, 1) * 255)));
                try self.glyph_uploads.append(self.gpa, .{
                    .x = slot.x,
                    .y = slot.y,
                    .w = w,
                    .h = h,
                    .ptr = at,
                });
            }
        }
        try self.glyphs.put(self.gpa, key, slot);
        return slot;
    }

    fn strokes(self: *Scene, n: *const m.Node, ctm: Affine, clip: u32, opacity: f32, fill: Fill) !void {
        if (render.strokeIsRing(n)) {
            const d = render.ringInsets(n);
            const s = try self.ringShape(n, ctm, d[0], d[1]) orelse return;
            for (try self.ownPaints(n, n.strokes)) |*p| {
                if (!p.visible) continue;
                if (p.kind == .pattern) {
                    const b = self.shape_bounds.items[s];
                    try self.patternPaint(n, p, try self.sess.renderer.strokeBox(n), ctm, clip, fill, .{
                        .chunks = .{
                            .first = s,
                            .count = 1,
                        },
                        .op = .none,
                        .bounds = .{
                            .x0 = @floatFromInt(b.x0),
                            .y0 = @floatFromInt(b.y0),
                            .x1 = @floatFromInt(b.x1),
                            .y1 = @floatFromInt(b.y1),
                        },
                    }, opacity);
                    continue;
                }
                const paint = try self.paintFor(p, n.size, ctm) orelse continue;
                try self.addPrim(s, none, .none, clip, paint, opacity * p.opacity, .stroke_ring);
            }
            return;
        }
        const dp = try self.devPolys(n, stroke_part, ctm);
        if (dp.fresh) {
            const r = &self.sess.renderer;
            var shape: Path = .{};
            defer shape.deinit(self.gpa);
            _ = try r.fillPath(n, &shape);
            const sg = try r.strokeDevice(n, &shape, ctm, &dp.d.polys);
            dp.d.winding = sg.winding;
            dp.d.op = sg.op;
            // The fill's coverage cuts the stroke only where the CPU has a fill mask.
            dp.d.has_fill = shape.verbs.items.len > 0;
            seal(dp.d);
        }
        const sg = dp.d;
        const ch = try self.chunksOf(dp.d);
        const has_fill = dp.d.has_fill;
        for (try self.ownPaints(n, n.strokes)) |*p| {
            if (!p.visible) continue;
            if (p.kind == .pattern) {
                try self.patternPaint(n, p, try self.sess.renderer.strokeBox(n), ctm, clip, fill, .{
                    .chunks = ch,
                    .op = if (!has_fill) .none else switch (sg.op) {
                        .none => .none,
                        .intersect => .intersect,
                        .subtract => .subtract,
                    },
                    .bounds = sg.bounds,
                }, opacity);
                continue;
            }
            const paint = try self.paintFor(p, n.size, ctm) orelse continue;
            var k: u32 = 0;
            while (k < ch.count) : (k += 1) {
                const s = ch.first + k;
                var op: Op = switch (sg.op) {
                    .none => .none,
                    .intersect => .intersect,
                    .subtract => .subtract,
                };
                if (!has_fill) op = .none;
                var s2: u32 = none;
                if (op != .none) {
                    s2 = switch (fill) {
                        .none, .hidden => none,
                        .formula => |f| f,
                        .path => |fc| self.cellShape(fc, self.shape_cells.items[s]),
                    };
                    if (s2 == none) {
                        // No fill here: inside keeps nothing, outside keeps everything.
                        if (op == .intersect) continue;
                        op = .none;
                    }
                }
                try self.addPrim(s, s2, op, clip, paint, opacity * p.opacity, .stroke_path);
            }
        }
    }

    /// The atlas shape of `ch` standing for `at`, or `none`.
    fn cellShape(self: *Scene, ch: Chunks, at: [2]i32) u32 {
        var k: u32 = 0;
        while (k < ch.count) : (k += 1) {
            const c = self.shape_cells.items[ch.first + k];
            if (c[0] == at[0] and c[1] == at[1]) return ch.first + k;
        }
        return none;
    }

    // ------------------------------------------------------------------ shapes

    /// The node's fill shape: a formula for rectangles and ellipses without stored
    /// geometry, atlas entries for paths.
    fn fillOf(self: *Scene, n: *const m.Node, ctm: Affine) !Fill {
        if (render.use_geometry and n.geometry.len > 0) return pathFill(try self.pathChunks(n, 0, ctm));
        switch (n.kind) {
            .frame, .component, .component_set, .instance, .rectangle => {
                const s = try self.rectShape(ctm, .{
                    .x1 = n.size.x,
                    .y1 = n.size.y,
                }, normRadii(n.size.x, n.size.y, n.radius), .rect, .{}) orelse return .hidden;
                return .{
                    .formula = s,
                };
            },
            .ellipse => {
                const s = try self.rectShape(ctm, .{
                    .x1 = n.size.x,
                    .y1 = n.size.y,
                }, .{ 0, 0, 0, 0 }, .ellipse, .{}) orelse return .hidden;
                return .{
                    .formula = s,
                };
            },
            .vector => if (n.network) |net| if (net.regions.len > 0) return pathFill(try self.pathChunks(n, 0, ctm)),
            else => {},
        }
        return .none;
    }

    /// The ring between the node's box moved in by `outer` and by `inner` (top, right,
    /// bottom, left), as `Renderer.strokeDevice` builds it.
    fn ringShape(self: *Scene, n: *const m.Node, ctm: Affine, outer: [4]f32, inner: [4]f32) !?u32 {
        const o = insetRect(n.size, n.radius, outer) orelse return null;
        const in = insetRect(n.size, n.radius, inner);
        return self.rectShape(ctm, o.rect, o.radii, .rect, .{
            .inner = if (in) |i| i.rect else null,
            .inner_radii = if (in) |i| i.radii else .{ 0, 0, 0, 0 },
        });
    }

    const RectShapeOptions = struct {
        /// The hole cut out of the shape (node space); without it, the shape is whole.
        inner: ?geom.Rect = null,
        inner_radii: [4]f32 = .{ 0, 0, 0, 0 },
    };

    /// A formula shape: `outer` (node space) with `radii`, less `options.inner` when given.
    fn rectShape(self: *Scene, ctm: Affine, outer: geom.Rect, radii: [4]f32, kind: ShapeKind, options: RectShapeOptions) !?u32 {
        var s: Shape = .{
            .kind = @backingInt(kind),
            .next = none,
            .layer = 0,
            .flags = if (options.inner != null) 1 else 0,
            .inv = .{ 1, 0, 0, 1 },
            .inv_t = .{ 0, 0, 0, 0 },
            .outer = .{ outer.x0, outer.y0, outer.x1, outer.y1 },
            .outer_r = radii,
            .inner = if (options.inner) |r| .{ r.x0, r.y0, r.x1, r.y1 } else .{ 0, 0, 0, 0 },
            .inner_r = options.inner_radii,
        };
        if (ctm.b == 0 and ctm.c == 0 and ctm.a == ctm.d and ctm.a > 0) {
            // Upright and evenly scaled: the shape goes to top space as the CPU's path
            // does (its points through `ctm`), so the edges are the same numbers.
            s.outer = mapRect(ctm, outer);
            s.outer_r = scaled(radii, ctm.a);
            if (options.inner) |r| {
                s.inner = mapRect(ctm, r);
                s.inner_r = scaled(options.inner_radii, ctm.a);
            }
        } else {
            const inv = ctm.invert() orelse return null;
            s.inv = .{ inv.a, inv.b, inv.c, inv.d };
            s.inv_t = .{ inv.e, inv.f, 0, 0 };
        }
        const b = IRect.around(geom.Rect.transformed(outer, ctm)).outset(1);
        if (b.intersect(self.view).isEmpty()) return null;
        return try self.pushShape(s, b, .{ 0, 0 });
    }

    fn pushShape(self: *Scene, s: Shape, bounds: IRect, at: [2]i32) !u32 {
        const i: u32 = @intCast(self.shapes.items.len);
        try self.shapes.append(self.gpa, s);
        try self.shape_bounds.append(self.gpa, bounds);
        try self.shape_cells.append(self.gpa, at);
        return i;
    }

    /// A clip: shape `s` continuing chain `parent`, its bounds cut by the chain's.
    fn pushClip(self: *Scene, s: u32, parent: u32) !u32 {
        var c = self.shapes.items[s];
        c.next = parent;
        var b = self.shape_bounds.items[s];
        if (parent != none) b = b.intersect(self.shape_bounds.items[parent]);
        return self.pushShape(c, b, self.shape_cells.items[s]);
    }

    /// The node's path `part` (0 the fill, 1 + i region i) in the atlas.
    fn pathChunks(self: *Scene, n: *const m.Node, part: u32, ctm: Affine) !Chunks {
        const key: PathKey = .{
            .node = @intFromPtr(n),
            .part = part,
        };
        const got = try self.paths.getOrPut(self.gpa, key);
        if (!got.found_existing) {
            got.value_ptr.* = .{
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
        const dp = try self.devPolys(n, part, ctm);
        if (dp.fresh) {
            try render.devicePolys(self.gpa, &got.value_ptr.path, ctm, &dp.d.polys);
            dp.d.winding = got.value_ptr.winding;
            seal(dp.d);
        }
        return self.chunksOf(dp.d);
    }

    /// Top-space polylines into the atlas: one entry per cell they cover in view.
    fn chunksOf(self: *Scene, dp: *const DevPolys) !Chunks {
        return self.chunksWith(dp, dp.bounds, &.{});
    }

    /// `chunksOf` over `bounds`, adding glyph masks into the entries.
    fn chunksWith(self: *Scene, dp: *const DevPolys, bounds: geom.Rect, glyphs: []const GlyphRect) !Chunks {
        const polys = &dp.polys;
        const winding = dp.winding;
        const first: u32 = @intCast(self.shapes.items.len);
        const area = IRect.around(bounds).intersect(self.view);
        if (area.isEmpty()) return .{
            .first = first,
            .count = 0,
        };
        var cy = @divFloor(area.y0, cell);
        while (cy * cell < area.y1) : (cy += 1) {
            var cx = @divFloor(area.x0, cell);
            while (cx * cell < area.x1) : (cx += 1) {
                const r = area.intersect(.{
                    .x0 = cx * cell,
                    .y0 = cy * cell,
                    .x1 = (cx + 1) * cell,
                    .y1 = (cy + 1) * cell,
                });
                if (r.isEmpty()) continue;
                try self.atlasEntry(polys, winding, r, .{ cx, cy }, glyphs);
            }
        }
        return .{
            .first = first,
            .count = @as(u32, @intCast(self.shapes.items.len)) - first,
        };
    }

    /// Places `r` (top space) in the atlas and adds the stencil triangles of `polys`
    /// there, cut to a pixel around `r`.
    fn atlasEntry(self: *Scene, polys: *const Polylines, winding: mask_mod.Winding, r: IRect, at: [2]i32, glyphs: []const GlyphRect) !void {
        const w = r.width() * 2 + atlas_pad * 2;
        const h = r.height() * 2 + atlas_pad * 2;
        if (self.layers.items.len == 0 or self.shelf_x + w > atlas_size) {
            self.shelf_x = 0;
            self.shelf_y += self.shelf_h;
            self.shelf_h = 0;
        }
        if (self.layers.items.len == 0 or self.shelf_y + h > atlas_size) {
            self.closeLayer();
            try self.layers.append(self.gpa, .{
                .vert_first = @intCast(self.verts.items.len),
                .vert_count = 0,
                .entry_first = @intCast(self.entries.items.len),
                .entry_count = 0,
                .glyph_first = @intCast(self.glyph_draws.items.len),
                .glyph_count = 0,
            });
            self.shelf_x = 0;
            self.shelf_y = 0;
            self.shelf_h = 0;
        }
        const layer: u32 = @intCast(self.layers.items.len - 1);
        const ex = self.shelf_x;
        const ey = self.shelf_y;
        self.shelf_x += w;
        self.shelf_h = @max(self.shelf_h, h);
        try self.entries.append(self.gpa, .{
            .layer = layer,
            .rule = if (winding == .evenodd) 1 else 0,
            .x = ex,
            .y = ey,
            .w = w,
            .h = h,
        });
        const ax: f32 = @floatFromInt(ex + atlas_pad);
        const ay: f32 = @floatFromInt(ey + atlas_pad);
        const rx: f32 = @floatFromInt(r.x0);
        const ry: f32 = @floatFromInt(r.y0);
        const lim: geom.Rect = .{
            .x0 = rx - 1,
            .y0 = ry - 1,
            .x1 = @as(f32, @floatFromInt(r.x1)) + 1,
            .y1 = @as(f32, @floatFromInt(r.y1)) + 1,
        };
        for (polys.contours.items) |c| {
            var pts = polys.contour(c);
            var cb: geom.Rect = .empty;
            for (pts) |p| cb.include(p);
            if (cb.x1 < lim.x0 or cb.y1 < lim.y0 or cb.x0 > lim.x1 or cb.y0 > lim.y1) {
                // Wholly outside: it still winds the inside, unless it covers nothing
                // here at all (it is past one side).
                continue;
            }
            if (cb.x0 < lim.x0 or cb.y0 < lim.y0 or cb.x1 > lim.x1 or cb.y1 > lim.y1) {
                try self.clipContour(pts, lim);
                pts = self.clipped.items;
            }
            if (pts.len < 3) continue;
            const p0 = pts[0];
            var i: usize = 1;
            while (i + 1 < pts.len) : (i += 1) {
                for ([3]Vec2{ p0, pts[i], pts[i + 1] }) |p| {
                    try self.verts.append(self.gpa, .{ ax + (p.x - rx) * 2, ay + (p.y - ry) * 2 });
                }
            }
        }
        for (glyphs) |g| {
            const c = g.rect.intersect(r);
            if (c.isEmpty()) continue;
            try self.glyph_draws.append(self.gpa, .{
                .layer = layer,
                .dx = ex + atlas_pad + @as(u32, @intCast(c.x0 - r.x0)) * 2,
                .dy = ey + atlas_pad + @as(u32, @intCast(c.y0 - r.y0)) * 2,
                .w = c.width(),
                .h = c.height(),
                .sx = g.sx + @as(u32, @intCast(c.x0 - g.rect.x0)),
                .sy = g.sy + @as(u32, @intCast(c.y0 - g.rect.y0)),
            });
        }
        _ = try self.pushShape(.{
            .kind = @backingInt(ShapeKind.atlas),
            .next = none,
            .layer = layer,
            .flags = 0,
            .inv = .{ 1, 0, 0, 1 },
            .inv_t = .{ 0, 0, 0, 0 },
            .outer = .{ rx, ry, @floatFromInt(r.x1), @floatFromInt(r.y1) },
            .outer_r = .{ ax, ay, 0, 0 },
            .inner = .{ 0, 0, 0, 0 },
            .inner_r = .{ 0, 0, 0, 0 },
        }, r, at);
    }

    /// A closed contour cut to `lim` (Sutherland-Hodgman) into `clipped`. Cut contours
    /// keep their winding number at every point inside `lim`.
    fn clipContour(self: *Scene, pts: []const Vec2, lim: geom.Rect) !void {
        self.clipped.clearRetainingCapacity();
        try self.clipped.appendSlice(self.gpa, pts);
        inline for (0..4) |side| {
            std.mem.swap(std.ArrayList(Vec2), &self.clipped, &self.clip_tmp);
            self.clipped.clearRetainingCapacity();
            const src = self.clip_tmp.items;
            if (src.len > 0) {
                var prev = src[src.len - 1];
                for (src) |cur| {
                    const in_c = inside(cur, lim, side);
                    const in_p = inside(prev, lim, side);
                    if (in_c != in_p) try self.clipped.append(self.gpa, cross(prev, cur, lim, side));
                    if (in_c) try self.clipped.append(self.gpa, cur);
                    prev = cur;
                }
            }
        }
    }

    // ------------------------------------------------------------------ surfaces

    const Saved = struct {
        ox: i32,
        oy: i32,
        view: IRect,
        surface: u32,
    };

    /// Later draws go to a new surface over `rect` (top space): its texel (0, 0) is
    /// `rect`'s top left, and it is what the walk sees as its view until `endSurface`.
    /// `n`, `part` and `sub` say what it draws (with `ctm` and `rect`, its key).
    fn beginSurface(self: *Scene, rect0: IRect, n: *const m.Node, part: u32, sub: u32, ctm: Affine) !Saved {
        return self.beginSurfaceRev(rect0, n, part, sub, ctm, 0);
    }

    /// `beginSurface` whose pixels also depend on what changes `rev2` stands for (a
    /// pattern's source).
    fn beginSurfaceRev(self: *Scene, rect0: IRect, n: *const m.Node, part: u32, sub: u32, ctm: Affine, rev2: u32) !Saved {
        const rect = limitSurface(rect0);
        const si: u32 = @intCast(self.surfaces.items.len);
        // The node's subtree revision: an edit under it gives the surface a new key, so
        // a host never draws pixels kept from before the edit.
        const Key = extern struct {
            node: u64,
            part: u32,
            sub: u32,
            ctm: [6]f32,
            rect: [4]i32,
            rev: u32,
            rev2: u32,
        };
        const kb: Key = .{
            .node = @intFromPtr(n),
            .part = part,
            .sub = sub,
            .ctm = .{ ctm.a, ctm.b, ctm.c, ctm.d, ctm.e, ctm.f },
            .rect = .{ rect.x0, rect.y0, rect.x1, rect.y1 },
            .rev = n.tree_rev,
            .rev2 = rev2,
        };
        const key = std.hash.Wyhash.hash(0, std.mem.asBytes(&kb));
        const base = std.hash.Wyhash.hash(1, std.mem.asBytes(&kb)[0..16]);
        try self.surfaces.append(self.gpa, .{
            .w = rect.width(),
            .h = rect.height(),
            .x0 = rect.x0,
            .y0 = rect.y0,
            // Pixels drawn while moving (polylines of another scale) are never kept.
            .flags = if (part == part_backdrop or self.motion) 0 else Surface.cacheable,
            .key_lo = @truncate(key),
            .key_hi = @truncate(key >> 32),
            .base = @truncate(base),
            .end = 0,
            .ctm = .{ ctm.a, ctm.b, ctm.c, ctm.d, ctm.e, ctm.f },
        });
        try self.open.append(self.gpa, si);
        try self.draws.append(self.gpa, .{
            .kind = Draw.begin,
            .first = si,
            .count = 0,
            .tex = none,
        });
        const saved: Saved = .{
            .ox = self.ox,
            .oy = self.oy,
            .view = self.view,
            .surface = si,
        };
        self.ox = -rect.x0;
        self.oy = -rect.y0;
        self.view = rect;
        self.header.surface_pixels +|= rect.width() * rect.height();
        return saved;
    }

    fn endSurface(self: *Scene, sv: Saved) !void {
        self.surfaces.items[sv.surface].end = @intCast(self.draws.items.len);
        try self.draws.append(self.gpa, .{
            .kind = Draw.end,
            .first = sv.surface,
            .count = 0,
            .tex = none,
        });
        _ = self.open.pop();
        self.ox = sv.ox;
        self.oy = sv.oy;
        self.view = sv.view;
    }

    fn surfaceRect(self: *const Scene, s: u32) IRect {
        const r = self.surfaces.items[s];
        return .{
            .x0 = r.x0,
            .y0 = r.y0,
            .x1 = r.x0 + @as(i32, @intCast(r.w)),
            .y1 = r.y0 + @as(i32, @intCast(r.h)),
        };
    }

    const SurfacePaintOptions = struct {
        /// Sampled with filtering, not pixel for pixel.
        filtered: bool = false,
    };

    fn surfacePaint(self: *Scene, s: u32, inv: Affine, options: SurfacePaintOptions) !u32 {
        return self.pushPaint(.{
            .kind = @backingInt(PaintKind.texture),
            .flags = @intFromBool(options.filtered),
            .a = s,
            .b = 0,
            .color = .{ 0, 0, 0, 0 },
            .inv = .{ inv.a, inv.b, inv.c, inv.d },
            .inv_t = .{ inv.e, inv.f, 0, 0 },
        });
    }

    fn solidPaint(self: *Scene, c: [4]f32) !u32 {
        return self.pushPaint(.{
            .kind = @backingInt(PaintKind.solid),
            .flags = 0,
            .a = 0,
            .b = 0,
            .color = c,
            .inv = .{ 1, 0, 0, 1 },
            .inv_t = .{ 0, 0, 0, 0 },
        });
    }

    fn pushPaint(self: *Scene, p: Paint) !u32 {
        const i: u32 = @intCast(self.paints.items.len);
        try self.paints.append(self.gpa, p);
        return i;
    }

    fn pushPass(self: *Scene, p: Pass) !void {
        const i: u32 = @intCast(self.passes.items.len);
        try self.passes.append(self.gpa, p);
        try self.draws.append(self.gpa, .{
            .kind = Draw.pass,
            .first = i,
            .count = 0,
            .tex = none,
        });
    }

    /// Extra composite settings of a primitive.
    const Extra = struct {
        blend: Blend = .normal,
        mask: u32 = none,
        mask_mode: MaskMode = .none,
        /// Composite by maximum (silhouettes grown by a shape).
        max: bool = false,
        /// Erase: the target times one minus the coverage.
        erase: bool = false,
    };

    /// A primitive over `bounds` (top space; cut to the view and the clip).
    fn emit(self: *Scene, bounds: IRect, shape: u32, shape2: u32, op: Op, clip: u32, paint: u32, opacity: f32, feature: Feature, x: Extra) !void {
        var b = bounds.intersect(self.view);
        if (clip != none) b = b.intersect(self.shape_bounds.items[clip]);
        if (b.isEmpty()) return;
        const pi: u32 = @intCast(self.prims.items.len);
        try self.prims.append(self.gpa, .{
            .x0 = @floatFromInt(b.x0 + self.ox),
            .y0 = @floatFromInt(b.y0 + self.oy),
            .x1 = @floatFromInt(b.x1 + self.ox),
            .y1 = @floatFromInt(b.y1 + self.oy),
            .shape = shape,
            .shape2 = shape2,
            .clip = clip,
            .paint = paint,
            .op = @backingInt(op),
            .ox = self.ox,
            .oy = self.oy,
            .feature = @backingInt(feature),
            .opacity = opacity,
            .blend = @backingInt(x.blend) | (@backingInt(x.mask_mode) << 8),
            .mask = x.mask,
        });
        self.header.features[@backingInt(feature)] += 1;
        const tex = self.paintTexture(paint);
        const mask_tex = if (x.mask != none) self.paintTexture(x.mask) else none;
        var flags: u32 = 0;
        if (x.blend != .normal) flags |= Draw.backdrop;
        if (x.max) flags |= Draw.max;
        if (x.erase) flags |= Draw.erase;
        if (flags == 0 and self.draws.items.len > 0) {
            const last = &self.draws.items[self.draws.items.len - 1];
            if (last.kind == Draw.prims and last.flags == 0 and last.mask == mask_tex and last.first + last.count == pi and (tex == none or last.tex == none or last.tex == tex)) {
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
            .mask = mask_tex,
            .flags = flags,
        });
    }

    /// The texture paint `p` reads (an image, a surface) or `none`.
    fn paintTexture(self: *const Scene, p: u32) u32 {
        const pt = self.paints.items[p];
        return switch (pt.kind) {
            @backingInt(PaintKind.image) => pt.a,
            @backingInt(PaintKind.texture), @backingInt(PaintKind.shadow) => surface_bit | pt.a,
            else => none,
        };
    }

    fn addPrim(self: *Scene, shape: u32, shape2: u32, op: Op, clip: u32, paint: u32, opacity: f32, feature: Feature) !void {
        var b = self.shape_bounds.items[shape];
        if (op == .intersect) b = b.intersect(self.shape_bounds.items[shape2]);
        return self.emit(b, shape, shape2, op, clip, paint, opacity, feature, .{});
    }

    /// A fill's primitive with the paint's blend mode.
    fn addPrimBlend(self: *Scene, shape: u32, clip: u32, paint: u32, opacity: f32, feature: Feature, blend: m.Blend) !void {
        return self.emit(self.shape_bounds.items[shape], shape, none, .none, clip, paint, opacity, feature, .{
            .blend = Blend.of(render.blendMode(blend)),
        });
    }

    /// Paint `paint` over `bounds` (a surface, mostly) with `opacity` and `blend`.
    fn composite(self: *Scene, bounds: IRect, clip: u32, paint: u32, opacity: f32, blend: Blend, feature: Feature) !void {
        return self.emit(bounds, none, none, .none, clip, paint, opacity, feature, .{
            .blend = blend,
        });
    }

    /// White over the fill's shape (its coverage as alpha), with `x`.
    fn coverPrims(self: *Scene, fill: Fill, x: Extra) !void {
        const white = try self.solidPaint(.{ 1, 1, 1, 1 });
        switch (fill) {
            .none, .hidden => {},
            .formula => |s| try self.emit(self.shape_bounds.items[s], s, none, .none, none, white, 1, .layer, x),
            .path => |ch| {
                var k: u32 = 0;
                while (k < ch.count) : (k += 1) try self.emit(self.shape_bounds.items[ch.first + k], ch.first + k, none, .none, none, white, 1, .layer, x);
            },
        }
    }

    // ------------------------------------------------------------------ effect passes

    const BlurRule = enum {
        /// `effects.blur`: Figma's kernel cut at the radius; three boxes past sigma 24.
        layer,
        /// `pixmap.blurAlpha`: three sigmas; three boxes past sigma 24.
        shadow,
    };

    /// Blurs surface `s` as the CPU blurs a layer or a shadow of `sigma` device pixels.
    fn blurPass(self: *Scene, s: u32, sigma: f32, rule: BlurRule) !void {
        if (!(sigma >= 0.05)) return;
        if (sigma > pix.exact_blur_limit) {
            const b = pix.boxSizes(sigma);
            return self.pushPass(.{
                .kind = @backingInt(PassKind.box3),
                .src = s,
                .dst = s,
                .i = .{ @intCast(b[0]), @intCast(b[1]), @intCast(b[2]), 0, 0, 0, 0, 0 },
            });
        }
        var sg = sigma;
        var r: i32 = undefined;
        switch (rule) {
            .layer => {
                sg = @round(sigma * 16) / 16;
                if (sg < 0.05) return;
                r = @intFromFloat(@max(1, @round(sg * efx.blur_reach)));
            },
            .shadow => r = @intFromFloat(@ceil(sigma * 3)),
        }
        var p: Pass = .{
            .kind = @backingInt(PassKind.gauss),
            .src = s,
            .dst = s,
            .i = .{ r, 0, 0, 0, 0, 0, 0, 0 },
        };
        p.f[0] = sg;
        return self.pushPass(p);
    }

    /// `effects.progressiveBlur` on surface `s` (`k`: sigma per unit of radius).
    fn progressivePass(self: *Scene, s: u32, n: *const m.Node, e: m.Effect, ctm: Affine, k: f32) !void {
        const pr = e.progressive orelse return;
        const inv = ctm.invert() orelse return;
        const start: Vec2 = .{
            .x = pr.start.x * n.size.x,
            .y = pr.start.y * n.size.y,
        };
        const end: Vec2 = .{
            .x = pr.end.x * n.size.x,
            .y = pr.end.y * n.size.y,
        };
        const dir = end.sub(start);
        const sc = ctm.maxScale() * k;
        var p: Pass = .{
            .kind = @backingInt(PassKind.progressive),
            .src = s,
            .dst = s,
        };
        p.f[0..14].* = .{ inv.a, inv.b, inv.c, inv.d, inv.e, inv.f, start.x, start.y, dir.x, dir.y, dir.x * dir.x + dir.y * dir.y, pr.start_radius * sc, e.radius * sc, efx.blur_reach };
        return self.pushPass(p);
    }

    /// `effects.drawNoise` on surface `s`.
    fn noisePass(self: *Scene, s: u32, e: m.Effect, ctm: Affine) !void {
        const inv = ctm.invert() orelse return;
        const pc = colour.solid(e.color);
        const sc = colour.solid(e.secondary);
        const ss: i32 = @intFromFloat(std.math.clamp(@ceil(2 / @max(ctm.maxScale(), 0.01)), 1, 4));
        var p: Pass = .{
            .kind = @backingInt(PassKind.noise),
            .src = s,
            .dst = s,
            .i = .{ @backingInt(e.noise), ss, 0, 0, 0, 0, 0, 0 },
        };
        p.f = .{
            inv.a,                                  inv.b,                                  inv.c,     inv.d, inv.e, inv.f,
            @max(e.grain.x * efx.grain_cell, 0.01), @max(e.grain.y * efx.grain_cell, 0.01), e.density, pc.r,  pc.g,  pc.b,
            pc.a,                                   sc.r,                                   sc.g,      sc.b,  sc.a,  e.opacity,
            efx.grain_density_k,                    efx.grain_edge,
        };
        return self.pushPass(p);
    }

    /// `effects.drawTexture` on surface `s`.
    fn texturePass(self: *Scene, n: *const m.Node, s: u32, e: m.Effect, ctm: Affine) !void {
        _ = n;
        const inv = ctm.invert() orelse return;
        var p: Pass = .{
            .kind = @backingInt(PassKind.texture),
            .src = s,
            .dst = s,
            .i = .{ @intFromBool(e.clip), 0, 0, 0, 0, 0, 0, 0 },
        };
        p.f[0..13].* = .{ inv.a, inv.b, inv.c, inv.d, inv.e, inv.f, ctm.a, ctm.b, ctm.c, ctm.d, @max(e.grain.x * efx.grain_cell, 0.01), @max(e.grain.y * efx.grain_cell, 0.01), e.radius * efx.texture_k };
        return self.pushPass(p);
    }

    /// Grows (or shrinks) surface `s`'s alpha by `d` pixels (`pixmap.spreadAlpha`).
    fn spreadPass(self: *Scene, s: u32, d: f32) !void {
        if (@abs(d) < 0.01) return;
        const whole = @floor(@abs(d));
        var p: Pass = .{
            .kind = @backingInt(PassKind.spread),
            .src = s,
            .dst = s,
            .i = .{ @intFromFloat(whole), @intFromBool(d > 0), 0, 0, 0, 0, 0, 0 },
        };
        p.f[0] = @abs(d) - whole;
        return self.pushPass(p);
    }

    // ------------------------------------------------------------------ shadows

    /// A shadow's shape when it is drawn by formula: the node's silhouette is its own
    /// rectangle (with corners) or ellipse, upright and evenly scaled.
    const FormulaShape = struct {
        ellipse: bool,
    };

    fn shadowFormula(self: *const Scene, n: *const m.Node, ctm: Affine) ?FormulaShape {
        _ = self;
        if (!formula_shadows) return null;
        if (render.use_geometry and n.geometry.len > 0) return null;
        const ellipse = switch (n.kind) {
            .frame, .component, .component_set, .instance, .rectangle => false,
            .ellipse => true,
            else => return null,
        };
        if (!(ctm.b == 0 and ctm.c == 0 and ctm.a == ctm.d and ctm.a > 0)) return null;
        for (n.effects) |e| {
            if (!e.visible) continue;
            switch (e.kind) {
                .noise, .texture, .layer_blur => return null,
                else => {},
            }
        }
        if (!render.shapeSilhouette(n)) {
            // A leaf whose opaque silhouette is its fill's coverage.
            if (n.children.len > 0) return null;
            var any = false;
            for (n.fills) |p| {
                if (!p.visible) continue;
                if (p.kind != .solid) return null;
                any = true;
            }
            if (!any) return null;
            if (hasVisible(n.strokes) and n.stroke.weight > 0 and n.stroke.alignFor(n.kind) != .inside) return null;
        }
        return .{
            .ellipse = ellipse,
        };
    }

    /// Whether the node's drop shadows spread (`Renderer.dropShadow`).
    pub fn spreads(n: *const m.Node) bool {
        return switch (n.kind) {
            .rectangle, .ellipse => true,
            .frame, .component, .component_set, .instance => n.clip,
            else => false,
        };
    }

    /// Whether a spread grows the node's shape itself (corners stay round).
    pub fn shaped(n: *const m.Node) bool {
        return hasVisible(n.fills) and switch (n.kind) {
            .frame, .component, .component_set, .instance, .rectangle, .ellipse => true,
            else => false,
        };
    }

    /// The node's box grown by `sp` (node units) as `Renderer.dropShadow` grows it, or
    /// null when nothing is left.
    pub fn grownBox(n: *const m.Node, sp: f32) ?struct {
        rect: geom.Rect,
        radii: [4]f32,
    } {
        const gw = @max(0, n.size.x + 2 * sp);
        const gh = @max(0, n.size.y + 2 * sp);
        if (gw <= 0 or gh <= 0) return null;
        var radii = n.radius;
        for (&radii) |*r| r.* = if (r.* > 0) @max(0, r.* + sp) else 0;
        return .{
            .rect = .{
                .x0 = -sp,
                .y0 = -sp,
                .x1 = -sp + gw,
                .y1 = -sp + gh,
            },
            .radii = if (n.kind == .ellipse) .{ 0, 0, 0, 0 } else normRadii(gw, gh, radii),
        };
    }

    fn formulaPaint(self: *Scene, box: [4]f32, radii: [4]f32, sigma: f32, ellipse: bool, inner: bool, color: m.Color) !u32 {
        const c = colour.solid(color);
        return self.pushPaint(.{
            .kind = @backingInt(PaintKind.shadow_formula),
            .flags = @as(u32, @intFromBool(ellipse)) | (@as(u32, @intFromBool(inner)) << 1),
            .a = 0,
            .b = @bitCast(sigma),
            .color = pix.premultiply(c.r, c.g, c.b, c.a),
            .inv = box,
            .inv_t = radii,
        });
    }

    /// A drop shadow by formula: the node's (grown) shape blurred, offset, knocked out
    /// where the node is.
    fn formulaShadow(self: *Scene, n: *const m.Node, e: m.Effect, ctm: Affine, clip: u32, f: FormulaShape) !void {
        const s = ctm.maxScale();
        const sigma = e.radius * s * render.shadow_k;
        const off = ctm.applyVector(e.offset);
        const sp = if (spreads(n)) e.spread else 0;
        const g = grownBox(n, sp) orelse return;
        var box = mapRect(ctm, g.rect);
        box = .{ box[0] + off.x, box[1] + off.y, box[2] + off.x, box[3] + off.y };
        const paint = try self.formulaPaint(box, scaled(g.radii, s), sigma, f.ellipse, false, e.color);
        const reach: i32 = @intFromFloat(@ceil(sigma * 3) + 2);
        const bounds = IRect.around(.{
            .x0 = box[0],
            .y0 = box[1],
            .x1 = box[2],
            .y1 = box[3],
        }).outset(reach);
        var knock: u32 = none;
        if (!e.behind) switch (try self.fillOf(n, ctm)) {
            .formula => |sh| knock = sh,
            else => {},
        };
        try self.emit(bounds, none, knock, if (knock != none) .subtract else .none, clip, paint, n.opacity, .shadow_formula, .{});
    }

    /// Where a drop shadow takes its alpha from.
    const Source = union(enum) {
        /// The node's fill shape.
        shape,
        /// A surface's alpha (the node's layer, or its opaque silhouette).
        surface: u32,
    };

    /// Mirrors `Renderer.dropShadow`: the source's alpha spread and blurred in a surface,
    /// composited shifted by the offset (bilinear), knocked out where the source is.
    fn dropShadow(self: *Scene, n: *const m.Node, e: m.Effect, ei: u32, ctm: Affine, clip: u32, src0: Source, opacity: f32) !void {
        const s = ctm.maxScale();
        const sigma = e.radius * s * render.shadow_k;
        const off = ctm.applyVector(e.offset);
        const spread = if (spreads(n)) e.spread * s else 0;
        const pad: i32 = @intFromFloat(@ceil(sigma * 3 + @max(spread, 0) + 2));
        var src = src0;
        // A path shape: its coverage in a surface first (the same thing to the shadow).
        if (src == .shape) {
            const fill = try self.fillOf(n, ctm);
            if (fill == .path) {
                const area = (try self.fillArea(n, ctm, fill)).intersect(self.view.outset(@intFromFloat(@ceil(render.effectExtent(n, ctm)))));
                if (area.isEmpty()) return;
                const sv = try self.beginSurface(area, n, part_cover, 0, ctm);
                try self.coverPrims(try self.fillOf(n, ctm), .{});
                try self.endSurface(sv);
                src = .{
                    .surface = sv.surface,
                };
            }
        }
        const src_rect = switch (src) {
            .shape => (try self.fillArea(n, ctm, try self.fillOf(n, ctm))).intersect(self.view.outset(@intFromFloat(@ceil(render.effectExtent(n, ctm))))),
            .surface => |sf| self.surfaceRect(sf),
        };
        if (src_rect.isEmpty()) return;
        const rect = src_rect.outset(pad);
        const sv = try self.beginSurface(rect, n, part_shadow, ei, ctm);
        const grow = shaped(n) and spread != 0;
        // The source's alpha; growing by shape, only what lies outside the node's own
        // shape keeps it (`max(grown, a * (1 - own))`).
        switch (src) {
            .shape => {
                const fill = try self.fillOf(n, ctm);
                const sh = switch (fill) {
                    .formula => |x| x,
                    else => none,
                };
                if (sh != none) {
                    const white = try self.solidPaint(.{ 1, 1, 1, 1 });
                    try self.emit(self.shape_bounds.items[sh], sh, if (grow) sh else none, if (grow) .subtract else .none, none, white, 1, .layer, .{});
                }
            },
            .surface => |sf| {
                const r = self.surfaceRect(sf);
                const paint = try self.surfacePaint(sf, translation(-r.x0, -r.y0), .{});
                if (grow) {
                    switch (try self.fillOf(n, ctm)) {
                        .formula => |sh| try self.emit(r, none, sh, .subtract, none, paint, 1, .layer, .{}),
                        .path => try self.emit(r, none, none, .none, none, paint, 1, .layer, .{
                            .mask = try self.surfacePaint(sf, translation(-r.x0, -r.y0), .{}),
                            .mask_mode = .inverse_alpha,
                        }),
                        .none, .hidden => try self.emit(r, none, none, .none, none, paint, 1, .layer, .{}),
                    }
                } else try self.emit(r, none, none, .none, none, paint, 1, .layer, .{});
            },
        }
        if (grow) {
            if (grownBox(n, e.spread)) |g| {
                const sh = try self.rectShape(ctm, g.rect, g.radii, if (n.kind == .ellipse) .ellipse else .rect, .{});
                if (sh) |x| {
                    const white = try self.solidPaint(.{ 1, 1, 1, 1 });
                    try self.emit(self.shape_bounds.items[x], x, none, .none, none, white, 1, .layer, .{
                        .max = true,
                    });
                }
            }
        } else try self.spreadPass(sv.surface, spread);
        try self.blurPass(sv.surface, sigma, .shadow);
        try self.endSurface(sv);

        const ix: i32 = @intFromFloat(@floor(off.x));
        const iy: i32 = @intFromFloat(@floor(off.y));
        const target: IRect = .{
            .x0 = rect.x0 + ix,
            .y0 = rect.y0 + iy,
            .x1 = rect.x1 + ix + 1,
            .y1 = rect.y1 + iy + 1,
        };
        const c = colour.solid(e.color);
        const paint = try self.pushPaint(.{
            .kind = @backingInt(PaintKind.shadow),
            .flags = 0,
            .a = sv.surface,
            .b = 0,
            .color = pix.premultiply(c.r, c.g, c.b, c.a),
            .inv = .{ 1, 0, 0, 1 },
            .inv_t = .{ -off.x - @as(f32, @floatFromInt(rect.x0)), -off.y - @as(f32, @floatFromInt(rect.y0)), 0, 0 },
        });
        if (e.behind) return self.emit(target, none, none, .none, clip, paint, opacity, .shadow_pass, .{});
        switch (src) {
            .shape => {
                const knock = switch (try self.fillOf(n, ctm)) {
                    .formula => |x| x,
                    else => none,
                };
                try self.emit(target, none, knock, if (knock != none) .subtract else .none, clip, paint, opacity, .shadow_pass, .{});
            },
            .surface => |sf| {
                const r = self.surfaceRect(sf);
                try self.emit(target, none, none, .none, clip, paint, opacity, .shadow_pass, .{
                    .mask = try self.surfacePaint(sf, translation(-r.x0, -r.y0), .{}),
                    .mask_mode = .inverse_alpha,
                });
            },
        }
    }

    /// `Renderer.coarseShadow`: one drop shadow on the coarse grid, from a silhouette
    /// drawn there, scaled up onto the target.
    fn coarseShadow(self: *Scene, n: *const m.Node, e: m.Effect, ei: u32, ctm: Affine, clip: u32, c: render.Coarse) !void {
        const lo_ctm = c.ctmFor(ctm);
        const crect = c.rectFor(self.view).outset(2);
        const sv = try self.beginSurface(crect, n, part_coarse, 1 + ei, lo_ctm);
        const ext = render.effectExtent(n, lo_ctm);
        const rect = IRect.around(render.visualBounds(n, lo_ctm)).intersect(crect.outset(@intFromFloat(@ceil(ext))));
        if (!rect.isEmpty()) {
            const ov = try self.beginSurface(rect, n, part_opaque, 0, lo_ctm);
            if (efx.hasTranslucentPaint(n)) self.opaque_of = n;
            defer self.opaque_of = null;
            try self.content(n, lo_ctm, none, 1);
            try self.endSurface(ov);
            self.opaque_of = null;
            try self.dropShadow(n, e, ei, lo_ctm, none, .{
                .surface = ov.surface,
            }, n.opacity);
        }
        try self.endSurface(sv);
        try self.coarseComposite(sv.surface, c, clip);
    }

    /// Mirrors `Renderer.innerShadow` (and `coarseInnerShadow`): the outside of the
    /// shape, shifted by the offset in whole pixels, spread and blurred, kept where the
    /// shape is.
    fn innerShadow(self: *Scene, n: *const m.Node, e: m.Effect, ei: u32, ctm: Affine, clip: u32, fill: Fill) !void {
        const scale = ctm.maxScale();
        const sigma = e.radius * scale * render.shadow_k;
        const coarse = render.Coarse.of(ctm, sigma);
        // By formula: a rectangle or ellipse, upright.
        if (coarse == null and formula_shadows and fill == .formula and !(render.use_geometry and n.geometry.len > 0) and ctm.b == 0 and ctm.c == 0 and ctm.a == ctm.d and ctm.a > 0) {
            const ellipse = n.kind == .ellipse;
            const off = ctm.applyVector(e.offset);
            const ix = @round(off.x);
            const iy = @round(off.y);
            // The outside grows by the spread: the shape shrinks by it.
            const d = e.spread * scale;
            var box = mapRect(ctm, .{
                .x1 = n.size.x,
                .y1 = n.size.y,
            });
            box = .{ box[0] + ix + d, box[1] + iy + d, box[2] + ix - d, box[3] + iy - d };
            var radii = if (ellipse) [4]f32{ 0, 0, 0, 0 } else scaled(normRadii(n.size.x, n.size.y, n.radius), scale);
            for (&radii) |*r| r.* = if (r.* > 0) @max(0, r.* - d) else 0;
            const paint = try self.formulaPaint(box, radii, sigma, ellipse, true, e.color);
            return self.emit(self.shape_bounds.items[fill.formula], fill.formula, none, .none, clip, paint, 1, .shadow_formula, .{});
        }
        const lo = if (coarse) |c| c.ctmFor(ctm) else ctm;
        const sc = lo.maxScale();
        const sg = e.radius * sc * render.shadow_k;
        const off = lo.applyVector(e.offset);
        const pad: i32 = @intFromFloat(@ceil(sg * 3 + @abs(e.spread * sc) + @max(@abs(off.x), @abs(off.y)) + 2));
        const ix: i32 = @intFromFloat(@round(off.x));
        const iy: i32 = @intFromFloat(@round(off.y));
        // The shape as far as the blur reads.
        const lo_view = if (coarse) |c| c.rectFor(self.view).outset(pad + 4) else self.view.outset(pad + 2);
        const saved_view = self.view;
        self.view = lo_view;
        const lo_fill = try self.fillOf(n, lo);
        const shape_rect = (try self.fillArea(n, lo, lo_fill)).intersect(lo_view);
        self.view = saved_view;
        if (shape_rect.isEmpty()) return;
        const rect = shape_rect.outset(pad);
        // The shape's coverage (a formula shape stands as it is).
        var cover: ?u32 = null;
        if (lo_fill == .path) {
            const cv = try self.beginSurface(shape_rect, n, part_cover, 1, lo);
            try self.coverPrims(try self.fillOf(n, lo), .{});
            try self.endSurface(cv);
            cover = cv.surface;
        }
        const sv = try self.beginSurface(rect, n, part_inner, ei, lo);
        const white = try self.solidPaint(.{ 1, 1, 1, 1 });
        try self.emit(rect, none, none, .none, none, white, 1, .layer, .{});
        // Erase the shape moved by the offset: what is left is its outside.
        if (cover) |cs| {
            const r = self.surfaceRect(cs);
            const paint = try self.surfacePaint(cs, translation(-r.x0 - ix, -r.y0 - iy), .{});
            try self.emit(.{
                .x0 = r.x0 + ix,
                .y0 = r.y0 + iy,
                .x1 = r.x1 + ix,
                .y1 = r.y1 + iy,
            }, none, none, .none, none, paint, 1, .layer, .{
                .erase = true,
            });
        } else switch (try self.fillOf(n, lo)) {
            .formula => |sh| {
                const moved = try self.movedShape(sh, ix, iy);
                try self.emit(self.shape_bounds.items[moved], moved, none, .none, none, white, 1, .layer, .{
                    .erase = true,
                });
            },
            else => {},
        }
        try self.spreadPass(sv.surface, e.spread * sc);
        try self.blurPass(sv.surface, sg, .shadow);
        try self.endSurface(sv);
        const ec = colour.solid(e.color);
        // Top space to the surface: whole texels, or the coarse grid's (bilinear).
        var inv = translation(-rect.x0, -rect.y0);
        if (coarse) |c| inv = .{
            .a = 1 / c.k,
            .d = 1 / c.k,
            .e = -c.ax / c.k - @as(f32, @floatFromInt(rect.x0)),
            .f = -c.ay / c.k - @as(f32, @floatFromInt(rect.y0)),
        };
        const paint = try self.pushPaint(.{
            .kind = @backingInt(PaintKind.shadow),
            .flags = 0,
            .a = sv.surface,
            .b = 0,
            .color = pix.premultiply(ec.r, ec.g, ec.b, ec.a),
            .inv = .{ inv.a, inv.b, inv.c, inv.d },
            .inv_t = .{ inv.e, inv.f, 0, 0 },
        });
        switch (fill) {
            .formula => |sh| try self.emit(self.shape_bounds.items[sh], sh, none, .none, clip, paint, 1, .shadow_pass, .{}),
            .path => |ch| {
                var k: u32 = 0;
                while (k < ch.count) : (k += 1) try self.emit(self.shape_bounds.items[ch.first + k], ch.first + k, none, .none, clip, paint, 1, .shadow_pass, .{});
            },
            .none, .hidden => {},
        }
    }

    /// A copy of formula shape `s` moved by whole pixels (top space).
    fn movedShape(self: *Scene, s: u32, dx: i32, dy: i32) !u32 {
        var c = self.shapes.items[s];
        const fx: f32 = @floatFromInt(dx);
        const fy: f32 = @floatFromInt(dy);
        // The shape's space from top space: x' = inv (p - d).
        c.inv_t[0] -= c.inv[0] * fx + c.inv[2] * fy;
        c.inv_t[1] -= c.inv[1] * fx + c.inv[3] * fy;
        c.next = none;
        const b = self.shape_bounds.items[s];
        return self.pushShape(c, .{
            .x0 = b.x0 + dx,
            .y0 = b.y0 + dy,
            .x1 = b.x1 + dx,
            .y1 = b.y1 + dy,
        }, .{ 0, 0 });
    }

    // ------------------------------------------------------------------ backdrops

    /// Mirrors `Renderer.backgroundBlur`: what is drawn behind the node, mirrored at the
    /// node's bounds and blurred, replaces it inside the node's shape.
    fn backgroundBlur(self: *Scene, n: *const m.Node, e: m.Effect, ei: u32, ctm: Affine, clip: u32) !void {
        const fill = try self.fillOf(n, ctm);
        if (fill == .none or fill == .hidden) return;
        const mk = (try self.fillArea(n, ctm, fill)).intersect(self.view);
        if (mk.isEmpty()) return;
        const sigma = efx.blurReach(e) * ctm.maxScale() * render.background_blur_k;
        const pad: i32 = @intFromFloat(@ceil(sigma * 3));
        const rect = mk.outset(pad).intersect(self.view);
        if (rect.isEmpty()) return;
        const ox = self.ox;
        const oy = self.oy;
        const sv = try self.beginSurface(rect, n, part_backdrop, ei, ctm);
        try self.endSurface(sv);
        try self.pushPass(.{
            .kind = @backingInt(PassKind.backdrop),
            .src = none,
            .dst = sv.surface,
            .i = .{ mk.x0, mk.y0, mk.x1, mk.y1, ox, oy, @intFromBool(render.background_blur_clamp), 0 },
        });
        if (e.progressive != null) {
            try self.progressivePass(sv.surface, n, e, ctm, render.background_blur_k);
        } else {
            try self.blurPass(sv.surface, sigma, .layer);
        }
        const paint = try self.surfacePaint(sv.surface, translation(-rect.x0, -rect.y0), .{});
        switch (fill) {
            .formula => |s| try self.emit(self.shape_bounds.items[s], s, none, .none, clip, paint, 1, .layer, .{
                .blend = .lerp,
            }),
            .path => |ch| {
                var k: u32 = 0;
                while (k < ch.count) : (k += 1) try self.emit(self.shape_bounds.items[ch.first + k], ch.first + k, none, .none, clip, paint, 1, .layer, .{
                    .blend = .lerp,
                });
            },
            .none, .hidden => {},
        }
    }

    // ------------------------------------------------------------------ patterns, masks

    /// Mirrors `Renderer.drawPatternIn`: the source node tiled over `box` (node space) in a
    /// surface over the fill (or stroke) area, composited through its coverage.
    fn patternPaint(self: *Scene, n: *const m.Node, p: *const m.Paint, box: geom.Rect, ctm: Affine, clip: u32, fill: Fill, stroke: ?StrokeCover, opacity: f32) !void {
        const src = self.sess.renderer.nodes.get(p.source) orelse return;
        const k = if (p.tile > 0) p.tile else 1;
        const cw = src.size.x * k;
        const ch = src.size.y * k;
        const tw = cw * (1 + p.spacing.x);
        const th = ch * (1 + p.spacing.y);
        if (tw <= 0.01 or th <= 0.01) return;
        const area = if (stroke) |st| IRect.around(st.bounds) else try self.fillArea(n, ctm, fill);
        const rect = area.intersect(self.view);
        if (rect.isEmpty()) return;
        const bw = box.x1 - box.x0;
        const bh = box.y1 - box.y0;
        const ox = box.x0 + render.alignStart(p.h_align, bw, cw);
        const oy = box.y0 + render.alignStart(p.v_align, bh, ch);
        const sub: u32 = @intCast((@intFromPtr(p) >> 3) & 0xffff);
        const sv = try self.beginSurfaceRev(rect, n, part_pattern, sub, ctm, src.tree_rev);
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
                try self.node(src, tile_ctm, none);
            }
        }
        try self.endSurface(sv);
        const paint = try self.surfacePaint(sv.surface, translation(-rect.x0, -rect.y0), .{});
        const a = opacity * p.opacity;
        if (stroke) |st| {
            var q: u32 = 0;
            while (q < st.chunks.count) : (q += 1) {
                const s = st.chunks.first + q;
                var op = st.op;
                var s2: u32 = none;
                if (op != .none) {
                    s2 = switch (fill) {
                        .none, .hidden => none,
                        .formula => |f| f,
                        .path => |fc| self.cellShape(fc, self.shape_cells.items[s]),
                    };
                    if (s2 == none) {
                        if (op == .intersect) continue;
                        op = .none;
                    }
                }
                try self.addPrimOp(s, s2, op, clip, paint, a);
            }
            return;
        }
        switch (fill) {
            .formula => |s| try self.emit(self.shape_bounds.items[s], s, none, .none, clip, paint, a, .layer, .{}),
            .path => |chs| {
                var q: u32 = 0;
                while (q < chs.count) : (q += 1) try self.emit(self.shape_bounds.items[chs.first + q], chs.first + q, none, .none, clip, paint, a, .layer, .{});
            },
            .none, .hidden => {},
        }
    }

    fn addPrimOp(self: *Scene, s: u32, s2: u32, op: Op, clip: u32, paint: u32, opacity: f32) !void {
        var b = self.shape_bounds.items[s];
        if (op == .intersect) b = b.intersect(self.shape_bounds.items[s2]);
        return self.emit(b, s, s2, op, clip, paint, opacity, .layer, .{});
    }

    /// Mirrors `Renderer.drawMasked`: the mask's coverage (its shape, alpha or luminance)
    /// and the siblings it masks each in a surface over `reach`, composited one through
    /// the other.
    fn maskRun(self: *Scene, parent: *const m.Node, index: usize, end: usize, ctm: Affine, clip: u32, reach: IRect) !void {
        const kids = parent.children;
        const mn = &kids[index];
        const mt = mn.mask orelse return;
        const mctm = ctm.mul(mn.transform);
        const mv = try self.beginSurface(reach, mn, part_mask, 0, mctm);
        switch (mt) {
            .vector => try self.outlineCover(mn, mctm),
            .alpha, .luminance => try self.node(mn, mctm, none),
        }
        try self.endSurface(mv);
        const kv = try self.beginSurface(reach, parent, part_masked, @intCast(index), ctm);
        for (kids[index + 1 .. end]) |*c| try self.node(c, ctm.mul(c.transform), none);
        try self.endSurface(kv);
        try self.emit(reach, none, none, .none, clip, try self.surfacePaint(kv.surface, translation(-reach.x0, -reach.y0), .{}), 1, .layer, .{
            .mask = try self.surfacePaint(mv.surface, translation(-reach.x0, -reach.y0), .{}),
            .mask_mode = if (mt == .luminance) .luminance else .alpha,
        });
    }

    /// `Renderer.outlineCoverage`: a mask by outline, a group's by its visible
    /// descendants' shapes together.
    fn outlineCover(self: *Scene, n: *const m.Node, ctm: Affine) !void {
        if (n.kind == .group) {
            for (n.children) |*c| if (c.visible) try self.outlineCover(c, ctm.mul(c.transform));
            return;
        }
        try self.coverPrims(try self.fillOf(n, ctm), .{});
    }

    // ------------------------------------------------------------------ paints and prims

    fn paintFor(self: *Scene, p: *const m.Paint, size: Vec2, ctm: Affine) !?u32 {
        // Decoded only as finely as this frame draws it (texture memory follows the view).
        if (p.kind == .image) try self.sess.ensurePaintAt(p, size, ctm);
        const sh = try self.sess.renderer.shaderFor(p, size, ctm) orelse return null;
        var out: Paint = .{
            .kind = 0,
            .flags = 0,
            .a = 0,
            .b = 0,
            .color = .{ 0, 0, 0, 0 },
            .inv = .{ 1, 0, 0, 1 },
            .inv_t = .{ 0, 0, 0, 0 },
        };
        switch (sh) {
            .solid => |c| {
                out.kind = @backingInt(PaintKind.solid);
                out.color = c;
            },
            .gradient => |g| {
                out.kind = switch (g.kind) {
                    .linear => @backingInt(PaintKind.linear),
                    .radial => @backingInt(PaintKind.radial),
                    .angular => @backingInt(PaintKind.angular),
                    .diamond => @backingInt(PaintKind.diamond),
                };
                out.a = @intCast(self.stops.items.len);
                out.b = @intCast(g.stops.len);
                for (g.stops) |st| {
                    try self.stops.append(self.gpa, .{ st.at, 0, 0, 0 });
                    try self.stops.append(self.gpa, st.color);
                }
                out.inv = .{ g.inverse.a, g.inverse.b, g.inverse.c, g.inverse.d };
                out.inv_t = .{ g.inverse.e, g.inverse.f, 0, 0 };
            },
            .image => |im| {
                out.kind = @backingInt(PaintKind.image);
                out.flags = @as(u32, @intFromBool(im.tile)) | (@as(u32, @intFromBool(im.decal)) << 1);
                out.a = try self.textureFor(p.asset, im.mip);
                out.b = @intCast(im.mip.levels.len);
                out.inv = .{ im.inverse.a, im.inverse.b, im.inverse.c, im.inverse.d };
                out.inv_t = .{ im.inverse.e, im.inverse.f, @floatFromInt(im.mip.levels[0].w), @floatFromInt(im.mip.levels[0].h) };
            },
        }
        const i: u32 = @intCast(self.paints.items.len);
        try self.paints.append(self.gpa, out);
        return i;
    }

    fn textureFor(self: *Scene, hash: []const u8, mip: *const pix.Mipmap) !u32 {
        const got = try self.texture_of.getOrPut(self.gpa, hash);
        if (got.found_existing) return got.value_ptr.*;
        const i: u32 = @intCast(self.textures.items.len);
        got.value_ptr.* = i;
        try self.textures.append(self.gpa, .{
            .hash_ptr = addr(hash.ptr),
            .hash_len = @intCast(hash.len),
            .width = mip.levels[0].w,
            .height = mip.levels[0].h,
            .levels = @intCast(mip.levels.len),
        });
        try self.texture_hashes.append(self.gpa, hash);
        try self.texture_first.append(self.gpa, mip.first);
        return i;
    }

    /// Hands part of `n` to the CPU: its pixels over `reach` (top space) go here in the
    /// draw order, under `clip`.
    fn fallback(self: *Scene, n: *const m.Node, ctm: Affine, clip: u32, part: Session.LayerPart, child: u32, reason: Reason, reach: IRect) !void {
        if (reach.isEmpty()) return;
        // A surface holding a CPU layer is not kept (the layer may still be coming).
        for (self.open.items) |si| self.surfaces.items[si].flags &= ~Surface.cacheable;
        const pi: u32 = @intCast(self.prims.items.len);
        try self.prims.append(self.gpa, .{
            .x0 = @floatFromInt(reach.x0 + self.ox),
            .y0 = @floatFromInt(reach.y0 + self.oy),
            .x1 = @floatFromInt(reach.x1 + self.ox),
            .y1 = @floatFromInt(reach.y1 + self.oy),
            .shape = none,
            .shape2 = none,
            .clip = clip,
            .paint = none,
            .op = 0,
            .ox = self.ox,
            .oy = self.oy,
            .feature = @backingInt(Feature.fallback),
            .opacity = 1,
        });
        const fi: u32 = @intCast(self.fallbacks.items.len);
        var full = IRect.around(render.cullBounds(n, ctm));
        if (part == .mask_run) {
            full = .{};
            const kids = n.children;
            var j = child + 1;
            while (j < kids.len and kids[j].mask == null) : (j += 1) full = full.unite(IRect.around(render.cullBounds(&kids[j], ctm.mul(kids[j].transform))));
        }
        try self.fallbacks.append(self.gpa, .{
            .id_ptr = addr(n.id.ptr),
            .id_len = @intCast(n.id.len),
            .part = @backingInt(part),
            .child = child,
            .reason = @backingInt(reason),
            .prim = pi,
            .rev = n.tree_rev,
            .ctm = .{ ctm.a, ctm.b, ctm.c, ctm.d, ctm.e, ctm.f },
            .rect = .{ reach.x0, reach.y0, reach.x1, reach.y1 },
            .full = .{ full.x0, full.y0, full.x1, full.y1 },
        });
        try self.fallback_ids.append(self.gpa, n.id);
        try self.fallback_revs.append(self.gpa, n.tree_rev);
        self.header.features[@backingInt(Feature.fallback)] += 1;
        self.header.reasons[@backingInt(reason)] += 1;
        try self.draws.append(self.gpa, .{
            .kind = Draw.fallback,
            .first = pi,
            .count = 1,
            .tex = fi,
        });
    }
};

/// Visible paints the node draws (fills, strokes with weight, region fills).
pub fn paintCount(n: *const m.Node) u32 {
    var paints: u32 = 0;
    for ([2][]const m.Paint{ n.fills, n.strokes }, 0..) |ps, k| for (ps) |p| {
        if (!p.visible) continue;
        if (k == 0 or n.stroke.weight > 0) paints += 1;
    };
    for (n.geometry) |g| if (g.fills) |fs| for (fs) |p| {
        if (p.visible) paints += 1;
    };
    return paints;
}

/// Whether a visible paint of the node has a blend mode of its own.
pub fn paintsBlend(n: *const m.Node) bool {
    for ([2][]const m.Paint{ n.fills, n.strokes }) |ps| for (ps) |p| {
        if (p.visible and p.blend != .normal) return true;
    };
    for (n.geometry) |g| if (g.fills) |fs| for (fs) |p| {
        if (p.visible and p.blend != .normal) return true;
    };
    return false;
}

pub fn translation(x: i32, y: i32) Affine {
    return Affine.translate(@floatFromInt(x), @floatFromInt(y));
}

/// A surface no wider or taller than a texture may be: cut around its middle.
fn limitSurface(r: IRect) IRect {
    var out = r;
    const lim: i32 = @intCast(max_surface);
    if (out.width() > max_surface) {
        const c = @divFloor(out.x0 + out.x1, 2);
        out.x0 = c - @divFloor(lim, 2);
        out.x1 = out.x0 + lim;
    }
    if (out.height() > max_surface) {
        const c = @divFloor(out.y0 + out.y1, 2);
        out.y0 = c - @divFloor(lim, 2);
        out.y1 = out.y0 + lim;
    }
    if (out.isEmpty()) out = .{
        .x0 = r.x0,
        .y0 = r.y0,
        .x1 = r.x0 + 1,
        .y1 = r.y0 + 1,
    };
    return out;
}

/// Takes the polylines' bounds once they are filled.
fn seal(d: *DevPolys) void {
    var b: geom.Rect = .empty;
    for (d.polys.points.items) |p| b.include(p);
    d.bounds = b;
}

fn pathFill(ch: Chunks) Fill {
    if (ch.count == 0) return .hidden;
    return .{
        .path = ch,
    };
}

/// `Session.place` with the view's corner in device pixels.
pub fn placeAt(c: *const m.Node, vx: f64, vy: f64, scale: f32) Session.Place {
    const t = c.transform;
    const s: f64 = scale;
    const ox = @as(f64, t.e) * s - vx;
    const oy = @as(f64, t.f) * s - vy;
    const big: f64 = 1 << 30;
    const dx = @round(std.math.clamp(ox, -big, big));
    const dy = @round(std.math.clamp(oy, -big, big));
    return .{
        .ctm = .{
            .a = scale * t.a,
            .b = scale * t.b,
            .c = scale * t.c,
            .d = scale * t.d,
            .e = @floatCast(ox - dx),
            .f = @floatCast(oy - dy),
        },
        .dx = @intFromFloat(dx),
        .dy = @intFromFloat(dy),
    };
}

/// Polylines under `from` moved to `to` (`to * from^-1`), when that is a near scaling: a
/// nearby scale of the same matrix, panned.
fn standIn(src: *const DevPolys, from_bits: [6]u32, to: Affine) ?Affine {
    if (src.approx or src.polys.points.items.len == 0) return null;
    const from: Affine = .{
        .a = @bitCast(from_bits[0]),
        .b = @bitCast(from_bits[1]),
        .c = @bitCast(from_bits[2]),
        .d = @bitCast(from_bits[3]),
        .e = @bitCast(from_bits[4]),
        .f = @bitCast(from_bits[5]),
    };
    const inv = from.invert() orelse return null;
    const mv = to.mul(inv);
    const k = mv.a;
    // Flattened for a scale up to four times off: still within a fifth of a pixel.
    if (!(k > 0.25 and k < 4)) return null;
    if (@abs(mv.d - k) > 1e-3 * k or @abs(mv.b) > 1e-3 * k or @abs(mv.c) > 1e-3 * k) return null;
    return mv;
}

fn glyphKey(g: text_layout.Placed, ctm: Affine, d: Vec2) GlyphKey {
    const gm = render.glyphTransform(g);
    return .{
        .font = @intFromPtr(g.font),
        .glyph = g.glyph,
        .scale = @bitCast(gm.a * ctm.a),
        .fx = @bitCast(d.x - @floor(d.x)),
        .fy = @bitCast(d.y - @floor(d.y)),
    };
}

fn freeText(gpa: Allocator, tc: *TextCache) void {
    for (tc.styles) |*tp| tp.path.deinit(gpa);
    gpa.free(tc.styles);
    tc.lay.deinit(gpa);
}

pub fn hasRegionFills(n: *const m.Node) bool {
    for (n.geometry) |g| if (g.fills != null) return true;
    return false;
}

pub fn hasVisible(ps: []const m.Paint) bool {
    for (ps) |p| if (p.visible) return true;
    return false;
}

/// Corner radii clamped as `Path.addRoundRect` clamps them.
pub fn normRadii(w: f32, h: f32, radii: [4]f32) [4]f32 {
    var r = radii;
    for (&r) |*v| v.* = @max(0, v.*);
    var f: f32 = 1;
    const sides = [4][3]f32{ .{ r[0], r[1], w }, .{ r[1], r[2], h }, .{ r[2], r[3], w }, .{ r[3], r[0], h } };
    for (sides) |s| {
        if (s[0] + s[1] > s[2] and s[0] + s[1] > 0) f = @min(f, s[2] / (s[0] + s[1]));
    }
    for (&r) |*v| v.* *= f;
    return r;
}

pub const Inset = struct {
    rect: geom.Rect,
    radii: [4]f32,
};

/// The rounded rectangle `render.addInset` builds, or null when it builds none.
pub fn insetRect(size: Vec2, radii: [4]f32, d: [4]f32) ?Inset {
    const w = size.x - d[1] - d[3];
    const h = size.y - d[0] - d[2];
    if (w <= 0 or h <= 0) return null;
    var r: [4]f32 = undefined;
    const adj = [4][2]usize{ .{ 3, 0 }, .{ 0, 1 }, .{ 1, 2 }, .{ 2, 3 } };
    for (&r, radii, adj) |*o, rad, a| o.* = if (rad > 0) @max(0, rad - @max(d[a[0]], d[a[1]])) else 0;
    // The path is built at the origin and moved by (d[3], d[0]).
    return .{
        .rect = .{
            .x0 = 0 + d[3],
            .y0 = 0 + d[0],
            .x1 = w + d[3],
            .y1 = h + d[0],
        },
        .radii = normRadii(w, h, r),
    };
}

pub fn mapRect(ctm: Affine, r: geom.Rect) [4]f32 {
    const p0 = ctm.apply(.{
        .x = r.x0,
        .y = r.y0,
    });
    const p1 = ctm.apply(.{
        .x = r.x1,
        .y = r.y1,
    });
    return .{ p0.x, p0.y, p1.x, p1.y };
}

pub fn scaled(r: [4]f32, k: f32) [4]f32 {
    return .{ r[0] * k, r[1] * k, r[2] * k, r[3] * k };
}

fn inside(p: Vec2, lim: geom.Rect, comptime side: usize) bool {
    return switch (side) {
        0 => p.x >= lim.x0,
        1 => p.x <= lim.x1,
        2 => p.y >= lim.y0,
        else => p.y <= lim.y1,
    };
}

fn cross(a: Vec2, b: Vec2, lim: geom.Rect, comptime side: usize) Vec2 {
    switch (side) {
        0, 1 => {
            const x = if (side == 0) lim.x0 else lim.x1;
            const t = (x - a.x) / (b.x - a.x);
            return .{
                .x = x,
                .y = a.y + (b.y - a.y) * t,
            };
        },
        else => {
            const y = if (side == 2) lim.y0 else lim.y1;
            const t = (y - a.y) / (b.y - a.y);
            return .{
                .x = a.x + (b.x - a.x) * t,
                .y = y,
            };
        },
    }
}

fn addr(p: anytype) u32 {
    return @truncate(@intFromPtr(p));
}

test "a frame with a clipped child and a ring stroke" {
    const gpa = std.testing.allocator;
    var s = try Session.create(gpa);
    defer s.destroy();
    try s.loadPubd(
        \\{"pubd":0,"name":"t","pages":[{"id":"0:1","type":"page","name":"P","children":[
        \\{"id":"1:1","type":"frame","name":"F","transform":[1,0,0,1,10,20],"size":[16,16],"radius":[4,4,4,4],
        \\"fills":[{"type":"solid","color":"#ff0000"}],"strokes":[{"type":"solid","color":"#000000"}],"stroke":{"weight":2},
        \\"clip":true,"children":[{"id":"1:2","type":"rectangle","name":"R","transform":[1,0,0,1,8,8],"size":[20,20],
        \\"fills":[{"type":"linear","stops":[{"at":0,"color":"#ff0000"},{"at":1,"color":"#0000ff"}],"handles":[[0,0.5],[1,0.5],[0,1]]}]}]}]}]}
    );
    var sc = Scene.init(gpa);
    defer sc.deinit();
    try sc.buildPage(s, 0, 0, 0, 2, 100, 100);
    // Frame fill, child fill, the stroke ring; the child clipped by the frame.
    try std.testing.expectEqual(@as(usize, 3), sc.prims.items.len);
    try std.testing.expectEqual(@as(u32, @backingInt(Feature.stroke_ring)), sc.prims.items[2].feature);
    const child = sc.prims.items[1];
    try std.testing.expect(child.clip != none);
    try std.testing.expectEqual(@as(u32, 1), sc.shapes.items[child.shape].kind);
    // Upright at scale 2: the frame's shape is in top space (its origin there, the
    // whole-pixel offset on the prim), radius 8.
    const fs = sc.shapes.items[sc.prims.items[0].shape];
    try std.testing.expectEqual(@as(f32, 0), fs.outer[0]);
    try std.testing.expectEqual(@as(f32, 32), fs.outer[2]);
    try std.testing.expectEqual(@as(i32, 20), sc.prims.items[0].ox);
    try std.testing.expectEqual(@as(f32, 19), sc.prims.items[0].x0);
    try std.testing.expectEqual(@as(f32, 8), fs.outer_r[0]);
    try std.testing.expectEqual(@as(u32, 2), sc.paints.items[child.paint].kind);
    try std.testing.expectEqual(@as(usize, 1), sc.draws.items.len);
}

test "paths go to the atlas, cut into cells" {
    const gpa = std.testing.allocator;
    var s = try Session.create(gpa);
    defer s.destroy();
    try s.loadPubd(
        \\{"pubd":0,"name":"t","pages":[{"id":"0:1","type":"page","name":"P","children":[
        \\{"id":"1:1","type":"vector","name":"V","transform":[1,0,0,1,0,0],"size":[1500,10],
        \\"fills":[{"type":"solid","color":"#ff0000"}],"geometry":[{"d":"M0 0L1500 0L1500 10L0 10Z"}]}]}]}
    );
    var sc = Scene.init(gpa);
    defer sc.deinit();
    try sc.buildPage(s, 0, 0, 0, 1, 2000, 100);
    try std.testing.expectEqual(@as(usize, 2), sc.prims.items.len);
    try std.testing.expectEqual(@as(usize, 2), sc.entries.items.len);
    try std.testing.expectEqual(@as(usize, 1), sc.layers.items.len);
    // Two triangles per cell (the rectangle cut to each cell is four points).
    try std.testing.expectEqual(@as(u32, 12), sc.layers.items[0].vert_count);
    try std.testing.expectEqual(@as(f32, 1016), sc.shapes.items[1].outer[0]);
}

test "effects, blend modes, opacity and masks become surfaces and passes, not CPU layers" {
    const gpa = std.testing.allocator;
    var s = try Session.create(gpa);
    defer s.destroy();
    try s.loadPubd(
        \\{"pubd":0,"name":"t","pages":[{"id":"0:1","type":"page","name":"P","children":[
        \\{"id":"1:1","type":"frame","name":"F","transform":[1,0,0,1,0,0],"size":[200,200],
        \\"fills":[{"type":"solid","color":"#ffffff"}],"clip":true,"children":[
        \\{"id":"1:2","type":"rectangle","name":"Card","transform":[1,0,0,1,20,20],"size":[60,40],
        \\"fills":[{"type":"solid","color":"#ff0000"}],"effects":[{"type":"drop-shadow","color":"#0000004d","offset":[0,4],"radius":8}]},
        \\{"id":"1:3","type":"vector","name":"V","transform":[1,0,0,1,100,20],"size":[40,40],
        \\"fills":[{"type":"solid","color":"#00ff00"}],"geometry":[{"d":"M0 0L40 0L20 40Z"}],
        \\"effects":[{"type":"drop-shadow","color":"#0000004d","offset":[0,4],"radius":8},{"type":"layer-blur","radius":4}]},
        \\{"id":"1:4","type":"rectangle","name":"M","transform":[1,0,0,1,20,100],"size":[60,60],"blend":"multiply",
        \\"fills":[{"type":"solid","color":"#0000ff"},{"type":"solid","color":"#00ff0080"}]},
        \\{"id":"1:5","type":"group","name":"G","transform":[1,0,0,1,100,100],"size":[60,60],"opacity":0.5,"children":[
        \\{"id":"1:6","type":"ellipse","name":"Mask","transform":[1,0,0,1,0,0],"size":[60,60],"mask":"vector","fills":[{"type":"solid","color":"#000000"}]},
        \\{"id":"1:7","type":"rectangle","name":"R","transform":[1,0,0,1,0,0],"size":[60,60],"fills":[{"type":"solid","color":"#ff00ff"}]}]}]}]}]}
    );
    var sc = Scene.init(gpa);
    defer sc.deinit();
    try sc.buildPage(s, 0, 0, 0, 1, 200, 200);
    try std.testing.expectEqual(@as(u32, 0), sc.header.fallback_count);
    // The card's shadow by formula; the triangle's from a surface (blurred, then cast).
    try std.testing.expectEqual(@as(u32, 1), sc.header.features[@backingInt(Feature.shadow_formula)]);
    try std.testing.expectEqual(@as(u32, 1), sc.header.features[@backingInt(Feature.shadow_pass)]);
    try std.testing.expect(sc.header.pass_count >= 2);
    // Surfaces begin and end in pairs, each end where its surface says.
    var depth: i32 = 0;
    for (sc.draws.items, 0..) |d, i| {
        if (d.kind == Draw.begin) depth += 1;
        if (d.kind == Draw.end) {
            depth -= 1;
            try std.testing.expectEqual(@as(u32, @intCast(i)), sc.surfaces.items[d.first].end);
        }
    }
    try std.testing.expectEqual(@as(i32, 0), depth);
    // The multiply node composites through the backdrop; the mask through its surface.
    var blended = false;
    var masked = false;
    for (sc.prims.items) |p| {
        if (p.blend & 0xff == @backingInt(pix.BlendMode.multiply)) blended = true;
        if (p.mask != none) masked = true;
    }
    try std.testing.expect(blended and masked);
}
