//! The Pubd document model in memory (pubd/SPEC.md, draft 0).
//!
//! A document owns everything it points to through one arena: build it, read it, drop it
//! whole.

const std = @import("std");
const geom = @import("../raster/geom.zig");

pub const Vec2 = geom.Vec2;
pub const Affine = geom.Affine;

/// Straight-alpha sRGB colour, each channel 0..1.
pub const Color = struct {
    r: f32 = 0,
    g: f32 = 0,
    b: f32 = 0,
    a: f32 = 1,
};

pub const Document = struct {
    arena: std.heap.ArenaAllocator,
    name: []const u8 = "",
    pages: []Node = &.{},
    styles: []Style = &.{},
    assets: []Asset = &.{},
    /// Nodes that pages draw from but that live on another page (a pattern's source),
    /// kept with the document so a page draws without reading the others.
    shared: []Node = &.{},
    /// For a document kept page by page (one per page, same order), each page's file and
    /// its top-level frames; empty when the pages sit in the document itself.
    chunks: []PageChunk = &.{},
    /// Glyph outlines that texts laid out by their source draw (`Text.glyphs`): SVG path
    /// data in ems, y up, shared by every page.
    glyphs: []const []const u8 = &.{},
    /// Every font the texts ask for (family and style), so the fonts a document lacks
    /// are known before its pages are read.
    fonts: []FontRef = &.{},
    /// Variable collections and their modes, and the variables in them (draft 2,
    /// pubd/SPEC.md "Variables").
    collections: []Collection = &.{},
    variables: []Variable = &.{},
    /// Every component and component set of a document kept page by page, so an
    /// instance knows its main (name, set, properties) before the main's page is read.
    components: []ComponentRef = &.{},

    pub fn deinit(self: *Document) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn asset(self: *const Document, hash: []const u8) ?*const Asset {
        for (self.assets) |*a| {
            if (std.mem.eql(u8, a.hash, hash)) return a;
        }
        return null;
    }
};

/// A font a text asks for.
pub const FontRef = struct {
    family: []const u8,
    style: []const u8 = "Regular",
    weight: u16 = 400,
    italic: bool = false,
};

/// Adds the fonts the texts under `n` ask for to `out` (each once; strings point into
/// the nodes).
pub fn collectFonts(gpa: std.mem.Allocator, n: *const Node, out: *std.ArrayList(FontRef)) !void {
    if (n.text) |t| {
        try addFont(gpa, t.style, out);
        for (t.runs) |r| {
            var st = r.style;
            if (st.family == null) st.family = t.style.family;
            try addFont(gpa, st, out);
        }
    }
    for (n.children) |*c| try collectFonts(gpa, c, out);
}

fn addFont(gpa: std.mem.Allocator, st: TextStyle, out: *std.ArrayList(FontRef)) !void {
    const family = st.family orelse return;
    const f: FontRef = .{
        .family = family,
        .style = st.font_style orelse "Regular",
        .weight = st.weight orelse 400,
        .italic = st.italic orelse false,
    };
    for (out.items) |x| if (std.mem.eql(u8, x.family, f.family) and std.mem.eql(u8, x.style, f.style)) return;
    try out.append(gpa, f);
}

/// A page kept in its own file: the file (a path beside `document.json`) and the page's
/// top-level nodes as the document lists them, so the page shows in lists and fits the
/// view before its file is read.
pub const PageChunk = struct {
    src: []const u8 = "",
    frames: []FrameInfo = &.{},
};

/// A top-level node of a page, as a document kept page by page lists it.
pub const FrameInfo = struct {
    id: []const u8,
    name: []const u8 = "",
    kind: Kind = .frame,
    /// Its box on the page: x0, y0, x1, y1.
    box: [4]f32 = .{ 0, 0, 0, 0 },
    /// Everything it may paint (effects and overflow included), on the page.
    bounds: [4]f32 = .{ 0, 0, 0, 0 },
};

pub const Asset = struct {
    /// SHA-256 of the bytes, lowercase hex.
    hash: []const u8,
    /// Media type, e.g. "image/png".
    type: []const u8,
    width: u32 = 0,
    height: u32 = 0,
};

pub const Kind = enum {
    page,
    frame,
    group,
    component,
    /// A component's variants side by side (Figma's component set): drawn as a frame.
    component_set,
    instance,
    rectangle,
    ellipse,
    /// A straight line from (0, 0) to (width, 0).
    line,
    /// A star: `count` points, inner radius `inner_scale` of the outer.
    star,
    /// A regular polygon with `count` sides.
    polygon,
    /// The union, intersection, difference or exclusion of its children (which it does
    /// not draw).
    boolean,
    /// An export area: never drawn.
    slice,
    vector,
    text,

    pub fn isContainer(k: Kind) bool {
        return switch (k) {
            .frame, .component, .component_set, .instance => true,
            else => false,
        };
    }
};

pub const Blend = enum {
    pass_through,
    normal,
    multiply,
    screen,
    overlay,
    darken,
    lighten,
    color_dodge,
    color_burn,
    linear_dodge,
    linear_burn,
    hard_light,
    soft_light,
    difference,
    exclusion,
    hue,
    saturation,
    color,
    luminosity,
};

pub const Node = struct {
    id: []const u8,
    kind: Kind,
    name: []const u8 = "",
    visible: bool = true,
    locked: bool = false,
    transform: Affine = .identity,
    size: Vec2 = .{},
    opacity: f32 = 1,
    blend: Blend = .pass_through,
    fills: []Paint = &.{},
    strokes: []Paint = &.{},
    stroke: Stroke = .{},
    effects: []Effect = &.{},
    styles: StyleRefs = .{},
    /// Host data as JSON text (`data` in the file), kept as written.
    data: ?[]const u8 = null,
    children: []Node = &.{},

    // page
    background: ?Color = null,
    /// The changes the page has had (`edits` in its file): what an engine that read an
    /// older file of it still has to apply.
    edits: u64 = 0,

    // containers and rectangles
    radius: [4]f32 = .{ 0, 0, 0, 0 },
    smoothing: f32 = 0,
    clip: bool = false,
    layout: ?Layout = null,
    grids: []Grid = &.{},
    component: ?[]const u8 = null,
    /// An instance scaled as a whole (Figma's scale tool): its content is its component's
    /// at this scale, before constraints and layout.
    scale: f32 = 1,

    // a child of any container
    constraints: Constraints = .{},
    sizing: ?Sizing = null,
    absolute: bool = false,
    /// Limits on the node's size that auto layout respects (null: none).
    min_width: ?f32 = null,
    max_width: ?f32 = null,
    min_height: ?f32 = null,
    max_height: ?f32 = null,
    /// A child of a grid layout: the cell it occupies.
    cell: ?Cell = null,

    // shapes
    arc: Arc = .{},
    network: ?Network = null,
    count: u32 = 0,
    inner_scale: f32 = 0,
    boolean_op: BooleanOp = .@"union",
    /// The resolved fill outline in node space, when known (vectors, stars, polygons,
    /// booleans): drawn as it is; a path's own fills replace the node's.
    geometry: []GeometryPath = &.{},

    /// Masks the siblings after it (until the next mask) instead of being drawn.
    mask: ?MaskType = null,
    /// Children stack in reverse: the first one on top.
    reverse_z: bool = false,
    /// A group drawing its children `count` times, shifted or turned (Figma's repeat).
    repeat: ?Repeat = null,

    // text
    text: ?Text = null,

    // components (pubd/SPEC.md, "Components")
    /// A component or component set: the properties its instances may set.
    properties: []PropDef = &.{},
    /// A node inside a main component: the component properties that drive its fields.
    bind: Bind = .{},
    /// An instance: the values it gives its main component's properties.
    props: []PropValue = &.{},
    /// An instance: the properties it overrides, by path below it ("" the instance
    /// itself). Null when the file does not say (older files): worked out when needed.
    overrides: ?[]Override = null,
    /// The variables the node's fields follow, by Pubd key (draft 2, "Variables").
    vars: []VarBinding = &.{},
    /// Variable modes the node sets for itself and everything in it, by collection.
    modes: []ModeChoice = &.{},

    /// The node's own content changed (not in the file): bumped by every edit of it but
    /// those of its paints' colours alone, so what is drawn of it is known to be stale
    /// (a change of colours alone is painted again in place).
    rev: u32 = 0,
    /// The node's shape changed (not in the file): bumped by every edit of it but those
    /// of its paints alone, so what is kept of its outline and its text's glyphs (paths,
    /// text layouts) is known to be stale.
    shape_rev: u32 = 0,
    /// The node or anything under it changed (not in the file): what is kept of its
    /// pixels (effect surfaces) is stale.
    tree_rev: u32 = 0,

    pub fn hasRadius(self: *const Node) bool {
        return self.radius[0] != 0 or self.radius[1] != 0 or self.radius[2] != 0 or self.radius[3] != 0;
    }
};

pub const PropKind = enum {
    /// Shows or hides the layers bound to it.
    boolean,
    /// A text layer's characters.
    text,
    /// The component a nested instance shows.
    instance_swap,
    /// Which variant of a component set an instance is.
    variant,
};

/// A component property a component or component set offers its instances.
pub const PropDef = struct {
    /// Unique in the component (a variant property's id is its name).
    id: []const u8,
    name: []const u8 = "",
    kind: PropKind = .text,
    /// The value an instance has unless it sets one, as JSON (`true`, `"Label"`, a
    /// component id, a variant value).
    default: []const u8 = "null",
    /// Variant: the values; instance swap: the components preferred for it.
    options: []const []const u8 = &.{},
};

/// A component or component set as `document.json` lists it (`components`).
pub const ComponentRef = struct {
    id: []const u8,
    name: []const u8 = "",
    /// `component` or `component_set`.
    kind: Kind = .component,
    /// The id of the page it is on.
    page: []const u8 = "",
    /// A variant: the id of its component set.
    set: []const u8 = "",
    properties: []PropDef = &.{},
};

/// The component properties that drive a node's fields (inside a main component).
pub const Bind = struct {
    /// Boolean property: the node's visibility.
    visible: ?[]const u8 = null,
    /// Text property: the node's characters.
    text: ?[]const u8 = null,
    /// Instance swap property: the nested instance's component.
    component: ?[]const u8 = null,

    pub fn isEmpty(b: Bind) bool {
        return b.visible == null and b.text == null and b.component == null;
    }
};

/// The value an instance gives one of its main component's properties.
pub const PropValue = struct {
    id: []const u8,
    /// JSON.
    value: []const u8,
};

/// What an instance overrides on one node below it.
pub const Override = struct {
    /// The node's path below the instance: its id with the instance's prefix
    /// (`I<instance>;`) left off ("" the instance itself).
    path: []const u8,
    /// Pubd keys (`fills`, `text`, `visible`, ...).
    keys: []const []const u8,
};

pub const StyleRefs = struct {
    fill: ?[]const u8 = null,
    stroke: ?[]const u8 = null,
    effect: ?[]const u8 = null,
    text: ?[]const u8 = null,
    grid: ?[]const u8 = null,
};

pub const PaintKind = enum {
    solid,
    linear,
    radial,
    angular,
    diamond,
    image,
    pattern,
};

pub const TileType = enum {
    rectangular,
    horizontal_hexagonal,
    vertical_hexagonal,
};

pub const TileAlign = enum {
    start,
    center,
    end,
};

pub const ScaleMode = enum {
    fill,
    fit,
    crop,
    tile,
    stretch,
};

pub const Stop = struct {
    at: f32,
    color: Color,
    /// The colour variable the stop's colour follows (its id), when bound.
    variable: ?[]const u8 = null,
};

pub const Paint = struct {
    kind: PaintKind,
    visible: bool = true,
    opacity: f32 = 1,
    blend: Blend = .normal,
    color: Color = .{},
    stops: []Stop = &.{},
    /// Gradient handles in the node's unit square: start, end, width.
    handles: [3]Vec2 = .{ .{}, .{}, .{} },
    asset: []const u8 = "",
    scale: ScaleMode = .fill,
    /// For `crop` and `stretch`: maps the node's unit square onto the image's.
    image_transform: Affine = .identity,
    tile: f32 = 1,
    /// Pattern: the node drawn as the tile, how tiles are laid out, the gap between them,
    /// and how the grid aligns to the filled box.
    source: []const u8 = "",
    tile_type: TileType = .rectangular,
    spacing: Vec2 = .{},
    h_align: TileAlign = .start,
    v_align: TileAlign = .start,
    /// The colour variable a solid paint's colour follows (its id), when bound.
    variable: ?[]const u8 = null,
    /// Other fields that follow variables (`opacity`).
    vars: []VarBinding = &.{},
};

pub const StrokeAlign = enum {
    center,
    inside,
    outside,
};

pub const Cap = enum {
    none,
    round,
    square,
};

pub const Join = enum {
    miter,
    round,
    bevel,
};

pub const Stroke = struct {
    weight: f32 = 1,
    /// Left out in the file: `inside` for containers and rectangles, `center` otherwise.
    @"align": ?StrokeAlign = null,
    cap: Cap = .none,
    join: Join = .miter,
    miter: f32 = 4,
    dashes: []f32 = &.{},
    /// Per side weights, top right bottom left.
    sides: ?[4]f32 = null,
    /// The resolved stroke outline in node space (SVG path data), when known: what the
    /// settings above produce, kept so any reader can draw it exactly (tools recompute it
    /// when the stroke changes). Inside and outside strokes are still clipped by the fill.
    outline: []OutlinePath = &.{},
    /// Variable width: the stroke's half widths at points along the path (empty: even).
    widths: []WidthPoint = &.{},
    /// A brush drawn along the path instead of a plain stroke.
    brush: ?Brush = null,
    /// A hand-drawn wobble along the path.
    dynamic: ?Dynamic = null,

    pub fn alignFor(self: Stroke, kind: Kind) StrokeAlign {
        if (self.@"align") |a| return a;
        return switch (kind) {
            .frame, .component, .component_set, .instance, .rectangle => .inside,
            else => .center,
        };
    }
};

/// One point of a variable-width stroke: in segment `segment` of the path, at `at`
/// (0..1 along it), the stroke reaches `ascent` to the left and `descent` to the right,
/// as fractions of the stroke weight (0.5 each is the plain width).
pub const WidthPoint = struct {
    segment: u32 = 0,
    at: f32 = 0,
    ascent: f32 = 0.5,
    descent: f32 = 0.5,
};

pub const BrushKind = enum {
    /// One shape bent along the whole path.
    stretch,
    /// A shape stamped repeatedly along the path.
    scatter,
};

/// How a scatter brush places its stamps.
pub const Scatter = struct {
    /// Space between stamps, as a fraction of the stamp size.
    gap: f32 = 0,
    /// Random offset across the path.
    wiggle: f32 = 0,
    /// Random turn, in degrees either way.
    angle_jitter: f32 = 0,
    /// Turn of every stamp, in degrees.
    rotation: f32 = 0,
    /// Random size change (0..1).
    size_jitter: f32 = 0,
};

/// A brush on a stroke: the brush's own shape and settings, kept with the node.
pub const Brush = struct {
    /// The brush's name (Figma's brushes are named, e.g. "Bubblegum").
    name: []const u8 = "",
    kind: BrushKind = .stretch,
    /// The brush's shape in its own space, `size` big.
    geometry: []GeometryPath = &.{},
    size: Vec2 = .{},
    /// Stretch: laid along the path backwards.
    reverse: bool = false,
    /// Scatter: the brush's stamp settings.
    scatter: ?Scatter = null,
    /// Scatter: the node's own stamp settings (in our files gap 1 and the rest 0, so
    /// apparently scales and offsets of the brush's).
    adjust: ?Scatter = null,
    /// Scatter: every stamp's placement, brush space to node space, as resolved.
    stamps: []Affine = &.{},
};

/// A hand-drawn stroke: the path wobbles `wiggle` units, `frequency` times per 100 units,
/// smoothed by `smoothen` (0..1).
pub const Dynamic = struct {
    frequency: f32 = 0,
    wiggle: f32 = 0,
    smoothen: f32 = 0,
};

pub const BooleanOp = enum {
    @"union",
    intersect,
    subtract,
    exclude,
};

pub const Repeat = struct {
    kind: RepeatKind = .linear,
    count: u32 = 1,
    /// Linear: the distance between copies. Radial: the diameter of the circle the
    /// copies turn on (they turn about the group's centre).
    offset: f32 = 0,
    vertical: bool = false,
};

pub const RepeatKind = enum {
    linear,
    radial,
};

pub const MaskType = enum {
    /// The mask's alpha.
    alpha,
    /// The mask's shape (coverage), whatever its paints.
    vector,
    /// The mask's luminance times its alpha.
    luminance,
};

pub const GeometryPath = struct {
    winding: Winding = .nonzero,
    /// SVG path data.
    d: []const u8,
    fills: ?[]Paint = null,
};

pub const OutlinePath = struct {
    winding: Winding = .nonzero,
    /// SVG path data: M, L, C, Q and Z, absolute.
    d: []const u8,
};

pub const EffectKind = enum {
    drop_shadow,
    inner_shadow,
    layer_blur,
    background_blur,
    /// Grain drawn over the node's content.
    noise,
    /// The node's content displaced by a grain, roughening its edges.
    texture,
};

/// How noise grain is coloured.
pub const NoiseType = enum {
    /// One colour.
    monotone,
    /// The colour and a second colour, on opposite grains.
    duotone,
    /// Every grain its own colour, at `opacity`.
    multitone,
};

/// A blur whose radius changes along a line, in the node's box (0..1 on each axis).
pub const Progressive = struct {
    start: Vec2 = .{},
    end: Vec2 = .{
        .y = 1,
    },
    /// Radius at `start`; the effect's `radius` holds at `end`.
    start_radius: f32 = 0,
};

pub const Effect = struct {
    kind: EffectKind,
    visible: bool = true,
    color: Color = .{
        .a = 0.25,
    },
    offset: Vec2 = .{},
    radius: f32 = 4,
    spread: f32 = 0,
    /// Drop shadows: also show through transparent parts of the node.
    behind: bool = false,
    blend: Blend = .normal,
    /// Blurs: the radius changes across the node.
    progressive: ?Progressive = null,
    /// Noise and texture: grain size in node units (x, y).
    grain: Vec2 = .{
        .x = 2,
        .y = 2,
    },
    /// Noise: how the grain is coloured (`color` is the first colour).
    noise: NoiseType = .monotone,
    /// Noise: how much of the node the grain covers (0..1).
    density: f32 = 0.5,
    /// Noise (duotone): the second colour.
    secondary: Color = .{},
    /// Noise (multitone): opacity of the grain colours.
    opacity: f32 = 1,
    /// Texture: keep the displaced content inside the node's shape.
    clip: bool = true,
    /// Noise and texture: the random seed of the grain.
    seed: u32 = 0,
    /// Fields that follow variables (`color`, `radius`, `spread`, `offset/0`, ...).
    vars: []VarBinding = &.{},
};

pub const Arc = struct {
    start: f32 = 0,
    end: f32 = std.math.tau,
    inner: f32 = 0,

    pub fn isFull(self: Arc) bool {
        return self.inner == 0 and @abs(self.end - self.start) >= std.math.tau - 1e-4;
    }
};

pub const Winding = enum {
    nonzero,
    evenodd,
};

pub const Segment = struct {
    from: u32,
    to: u32,
    t0: Vec2 = .{},
    t1: Vec2 = .{},
};

pub const Region = struct {
    winding: Winding = .nonzero,
    loops: [][]u32 = &.{},
};

pub const Network = struct {
    vertices: []Vec2 = &.{},
    segments: []Segment = &.{},
    regions: []Region = &.{},
};

pub const TextResize = enum {
    fixed,
    height,
    width_and_height,
    truncate,
};

pub const TextAlign = enum {
    left,
    center,
    right,
    justify,
};

pub const TextVAlign = enum {
    top,
    center,
    bottom,
};

pub const TextCase = enum {
    none,
    upper,
    lower,
    title,
    small_caps,
    small_caps_forced,
};

pub const Decoration = enum {
    none,
    underline,
    strikethrough,
};

pub const DecorationStyle = enum {
    solid,
    dotted,
    wavy,
};

pub const TextTruncation = enum {
    none,
    /// The last line that fits ends in an ellipsis.
    ending,
};

pub const TextWrap = enum {
    auto,
    /// Lines of a paragraph made as even in length as its line count allows.
    balance,
    pretty,
};

pub const LeadingTrim = enum {
    none,
    /// The box starts at the first line's cap height and ends at the last baseline.
    cap_height,
};

pub const ListType = enum {
    none,
    ordered,
    unordered,
};

/// One paragraph's list formatting.
pub const ParagraphList = struct {
    type: ListType = .none,
    /// Nesting level; 0 is no indentation.
    indent: u8 = 0,
};

/// Where text on a path starts: a segment of the node's network and a position in it.
pub const PathStart = struct {
    segment: u32 = 0,
    position: f32 = 0,
};

pub const LineHeight = union(enum) {
    auto,
    px: f32,
    percent: f32,
};

pub const LetterSpacing = union(enum) {
    px: f32,
    percent: f32,
};

/// Every field optional so a run can carry only what it changes.
pub const TextStyle = struct {
    family: ?[]const u8 = null,
    weight: ?u16 = null,
    italic: ?bool = null,
    font_style: ?[]const u8 = null,
    size: ?f32 = null,
    line_height: ?LineHeight = null,
    letter_spacing: ?LetterSpacing = null,
    paragraph_spacing: ?f32 = null,
    /// Extra indentation of each paragraph's first line, in pixels.
    paragraph_indent: ?f32 = null,
    case: ?TextCase = null,
    decoration: ?Decoration = null,
    /// How the decoration line is drawn.
    decoration_style: ?DecorationStyle = null,
    /// Fields that follow variables (`size`, `family`, `lineHeight`, ...).
    vars: []VarBinding = &.{},
};

pub const Run = struct {
    from: u32,
    to: u32,
    style: TextStyle = .{},
    fills: ?[]Paint = null,
};

pub const Text = struct {
    text: []const u8 = "",
    /// Underlines leave gaps where glyphs cross them.
    skip_ink: bool = true,
    style: TextStyle = .{},
    runs: []Run = &.{},
    resize: TextResize = .fixed,
    @"align": TextAlign = .left,
    valign: TextVAlign = .top,
    truncation: TextTruncation = .none,
    /// Lines shown at most (with truncation); null: as many as fit the box.
    max_lines: ?u32 = null,
    wrap: TextWrap = .auto,
    leading_trim: LeadingTrim = .none,
    /// Punctuation that starts a line hangs outside the box.
    hanging_punctuation: bool = false,
    /// List markers hang outside the box instead of indenting the text.
    hanging_list: bool = false,
    /// List formatting per paragraph, in order; paragraphs past the end are plain.
    lists: []ParagraphList = &.{},
    /// For text on a path (a text node with a network): where the text starts.
    path_start: PathStart = .{},
    /// The text as its source laid it out (Figma's own layout of it): each glyph's
    /// outline and place, and the underlines and strikethroughs. A cache, like a vector's
    /// geometry: drawn instead of laying the text out while a font it asks for is
    /// missing, so it looks as the source showed it; dropped when the text changes.
    glyphs: []TextGlyph = &.{},
    glyph_rects: []TextRect = &.{},
};

/// A glyph of a text as its source laid it out.
pub const TextGlyph = struct {
    /// Its outline: an index into the document's `glyphs`.
    outline: u32,
    /// The origin on the baseline, in the node's space.
    x: f32,
    y: f32,
    /// The font size: the outline (in ems, y up) is drawn this big.
    size: f32,
    /// The first character (UTF-16 index) it draws: its run gives its paints.
    char: u32 = 0,
    /// Turned about its origin (radians; text on a path).
    rotation: f32 = 0,
};

/// An underline or strikethrough of a text as its source laid it out.
pub const TextRect = struct {
    /// x, y, width, height in the node's space.
    rect: [4]f32,
    /// A character it belongs to (UTF-16 index): its run gives its paints.
    char: u32 = 0,
};

pub const LayoutMode = enum {
    horizontal,
    vertical,
    /// Children sit in the cells of `columns` x `rows` tracks.
    grid,
};

pub const MainAlign = enum {
    start,
    center,
    end,
    /// The free space goes between the children ("auto" gap).
    space_between,
    /// Half a share before the first child and after the last, a share between.
    space_around,
    /// Equal shares before, between and after the children.
    space_evenly,
};

/// How wrapped lines share the frame's cross axis.
pub const AlignContent = enum {
    /// Lines `cross_gap` apart, placed by `cross`.
    auto,
    /// The free space goes between the lines.
    space_between,
};

pub const TrackKind = enum {
    /// `value` pixels.
    fixed,
    /// A share (`value`, like CSS `fr`) of what fixed and hugging tracks leave.
    flex,
    /// As big as its largest single-track child.
    hug,
};

/// A grid column or row.
pub const Track = struct {
    kind: TrackKind = .flex,
    value: f32 = 1,
};

pub const CellAlign = enum {
    /// The frame's default (start).
    auto,
    start,
    center,
    end,
};

/// Where a grid child sits: its first column and row (0-based) and how many it spans,
/// and how it aligns inside that area.
pub const Cell = struct {
    column: u32 = 0,
    row: u32 = 0,
    column_span: u32 = 1,
    row_span: u32 = 1,
    h: CellAlign = .auto,
    v: CellAlign = .auto,
};

pub const CrossAlign = enum {
    start,
    center,
    end,
    baseline,
};

pub const AxisSizing = enum {
    fixed,
    hug,
};

pub const Layout = struct {
    mode: LayoutMode,
    wrap: bool = false,
    /// Between children; in a grid, between columns.
    gap: f32 = 0,
    /// Between wrapped lines; in a grid, between rows.
    cross_gap: f32 = 0,
    padding: [4]f32 = .{ 0, 0, 0, 0 },
    main: MainAlign = .start,
    cross: CrossAlign = .start,
    width: AxisSizing = .fixed,
    height: AxisSizing = .fixed,
    /// Wrapped lines across the frame.
    align_content: AlignContent = .auto,
    /// Strokes take space: a child's box grows by the part of its stroke outside it, and
    /// the frame's own stroke adds to its padding.
    strokes_included: bool = false,
    /// Grid tracks.
    columns: []Track = &.{},
    rows: []Track = &.{},
};

pub const ChildSizing = enum {
    fixed,
    hug,
    fill,
};

pub const Sizing = struct {
    w: ChildSizing = .fixed,
    h: ChildSizing = .fixed,
};

pub const HConstraint = enum {
    left,
    right,
    left_right,
    center,
    scale,
};

pub const VConstraint = enum {
    top,
    bottom,
    top_bottom,
    center,
    scale,
};

pub const Constraints = struct {
    h: HConstraint = .left,
    v: VConstraint = .top,
};

pub const GridKind = enum {
    columns,
    rows,
    grid,
};

pub const GridAlign = enum {
    stretch,
    start,
    center,
    end,
};

pub const Grid = struct {
    kind: GridKind = .columns,
    count: u32 = 0,
    gutter: f32 = 0,
    offset: f32 = 0,
    size: f32 = 0,
    @"align": GridAlign = .stretch,
    color: Color = .{
        .r = 1,
        .a = 0.1,
    },
    visible: bool = true,
    /// Fields that follow variables (`count`, `gutter`, `offset`, `size`).
    vars: []VarBinding = &.{},
};

pub const StyleKind = enum {
    fill,
    text,
    effect,
    grid,
};

pub const Style = struct {
    id: []const u8,
    kind: StyleKind,
    name: []const u8 = "",
    description: []const u8 = "",
    /// The style's value as Pubd JSON text, kept as written.
    value: ?[]const u8 = null,
    /// Copied from a library (another file): not one of the file's own styles.
    library: bool = false,
    /// The library's key for it (Figma's `key`).
    key: []const u8 = "",
    /// Removed, kept because layers still use it; editors leave it out of lists.
    deleted: bool = false,
};

/// A set of variables that share modes (Figma's collection), pubd/SPEC.md "Variables".
pub const Collection = struct {
    id: []const u8,
    name: []const u8 = "",
    /// The modes in order; the first is the default.
    modes: []VariableMode = &.{},
    /// Copied from a library (the variables' source is another file).
    library: bool = false,
    /// The library's key for it (Figma's `key`), so bindings by key find it.
    key: []const u8 = "",
    /// Hidden from publishing.
    hidden: bool = false,
    /// An extended collection: the collection it extends (its id). It has every variable
    /// of that one; its modes each extend one of the parent's (`VariableMode.parent`), and
    /// `overrides` replace the parent's values in its modes.
    parent: ?[]const u8 = null,
    overrides: []VariableOverride = &.{},
    /// Removed, kept because layers still use its variables (editors do not list it).
    deleted: bool = false,
};

pub const VariableMode = struct {
    id: []const u8,
    name: []const u8 = "",
    /// In an extended collection: the parent collection's mode this one extends.
    parent: ?[]const u8 = null,
};

/// An extended collection's own values of one of its parent's variables.
pub const VariableOverride = struct {
    /// The variable's id.
    variable: []const u8,
    /// By the extended collection's mode ids.
    values: []VariableValue = &.{},
};

pub const VariableType = enum {
    color,
    number,
    string,
    boolean,
};

/// What code calls a variable, per platform (Figma's code syntax).
pub const CodeSyntax = struct {
    web: []const u8 = "",
    ios: []const u8 = "",
    android: []const u8 = "",

    pub fn isEmpty(c: CodeSyntax) bool {
        return c.web.len == 0 and c.ios.len == 0 and c.android.len == 0;
    }
};

/// A named value per mode: a colour, a number, a string or a boolean, or an alias of
/// another variable.
pub const Variable = struct {
    id: []const u8,
    name: []const u8 = "",
    /// The collection's id.
    collection: []const u8 = "",
    type: VariableType = .color,
    description: []const u8 = "",
    values: []VariableValue = &.{},
    /// Where editors offer it, Figma's scope names lower-cased (`gap`, `corner-radius`);
    /// empty: everywhere.
    scopes: []const []const u8 = &.{},
    /// The library's key for it (a library variable, or one this file publishes).
    key: []const u8 = "",
    /// Hidden from publishing.
    hidden: bool = false,
    /// Removed, but kept because layers still use it (Figma keeps such variables).
    deleted: bool = false,
    code: CodeSyntax = .{},
};

pub const VariableValue = struct {
    /// The mode's id.
    mode: []const u8,
    /// The value as Pubd JSON text: a colour, a number, a string, a boolean,
    /// `{"alias":"<variable id>"}`, or `{"compose":{"color":C,"opacity":N}}` (a colour
    /// with its opacity from a number, each a value or an alias).
    value: []const u8,
};

/// A field that follows a variable: `key` is the field's Pubd key (`gap`, `padding/0`,
/// `radius/3`, `stroke/weight`, `width`) in the object that holds the binding,
/// `variable` the variable's id (or, for a library variable the file does not hold,
/// `key:<library key>`).
pub const VarBinding = struct {
    key: []const u8,
    variable: []const u8,
};

/// A mode a node sets for one collection: it and everything in it resolve that
/// collection's variables in that mode.
pub const ModeChoice = struct {
    collection: []const u8,
    mode: []const u8,
};

/// The weight a font style's name spells (`Semi Bold` 600, `Black Italic` 900).
pub fn weightOfStyle(style: []const u8) u16 {
    var buf: [64]u8 = undefined;
    var n: usize = 0;
    for (style) |c| {
        if (c == ' ' or c == '-' or c == '_') continue;
        if (n == buf.len) break;
        buf[n] = std.ascii.toLower(c);
        n += 1;
    }
    const s = buf[0..n];
    const table = .{
        .{ "extralight", 200 }, .{ "ultralight", 200 }, .{ "semibold", 600 }, .{ "demibold", 600 },
        .{ "extrabold", 800 },  .{ "ultrabold", 800 },  .{ "thin", 100 },     .{ "hairline", 100 },
        .{ "light", 300 },      .{ "medium", 500 },     .{ "bold", 700 },     .{ "black", 900 },
        .{ "heavy", 900 },
    };
    inline for (table) |e| if (std.mem.indexOf(u8, s, e[0]) != null) return e[1];
    return 400;
}

/// A deep copy of `v` in `a`: every slice and string it reaches is copied, so the copy
/// keeps nothing of where `v` lives (a reader builds in scratch memory, then keeps this).
pub fn deepCopy(a: std.mem.Allocator, v: anytype) error{OutOfMemory}!@TypeOf(v) {
    const T = @TypeOf(v);
    switch (@typeInfo(T)) {
        .optional => return if (v) |x| try deepCopy(a, x) else null,
        .pointer => |ptr| {
            if (ptr.size != .slice) return v;
            if (v.len == 0) return v;
            const out = try a.alloc(ptr.child, v.len);
            if (ptr.child == u8) {
                @memcpy(out, v);
            } else for (out, v) |*o, x| {
                o.* = try deepCopy(a, x);
            }
            return out;
        },
        .array => {
            var out: T = undefined;
            for (&out, v) |*o, x| o.* = try deepCopy(a, x);
            return out;
        },
        .@"struct" => |st| {
            var out: T = v;
            inline for (st.field_names) |field_name| @field(out, field_name) = try deepCopy(a, @field(v, field_name));
            return out;
        },
        .@"union" => |u| {
            if (u.tag_type == null) return v;
            switch (v) {
                inline else => |x, tag| return @unionInit(T, @tagName(tag), try deepCopy(a, x)),
            }
        },
        else => return v,
    }
}

/// A number that is not finite (NaN, ±inf) somewhere in a document: Pubd has no spelling
/// for one, so the writer refuses to write it and the reader refuses to keep it.
pub const NotFinite = struct {
    /// The node's id.
    node: []const u8 = "",
    /// The field, as a path through the model: `size.x`, `fills[0].stops[1].at`.
    buf: [160]u8 = undefined,
    len: usize = 0,

    pub fn field(self: *const NotFinite) []const u8 {
        return self.buf[0..self.len];
    }

    /// "node 4:103: size.x is not a finite number" in `out`.
    pub fn describe(self: *const NotFinite, out: []u8) []const u8 {
        return std.fmt.bufPrint(out, "node {s}: {s} is not a finite number", .{ self.node, self.field() }) catch "a number is not finite";
    }

    fn push(self: *NotFinite, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.bufPrint(self.buf[self.len..], fmt, args) catch return;
        self.len += s.len;
    }
};

/// The first number in the document that is not finite, in page order; null when there
/// is none.
pub fn findNotFinite(doc: *const Document) ?NotFinite {
    var p: NotFinite = .{};
    for (doc.pages) |*n| if (nodeNotFinite(n, &p)) return p;
    for (doc.shared) |*n| if (nodeNotFinite(n, &p)) return p;
    return null;
}

fn nodeNotFinite(n: *const Node, p: *NotFinite) bool {
    p.node = n.id;
    inline for (@typeInfo(Node).@"struct".field_names) |field_name| {
        if (comptime std.mem.eql(u8, field_name, "children")) continue;
        p.len = 0;
        p.push("{s}", .{field_name});
        if (valueNotFinite(@field(n, field_name), p)) return true;
    }
    for (n.children) |*c| if (nodeNotFinite(c, p)) return true;
    return false;
}

fn valueNotFinite(v: anytype, p: *NotFinite) bool {
    const T = @TypeOf(v);
    switch (@typeInfo(T)) {
        .float => return !std.math.isFinite(v),
        .optional => return if (v) |x| valueNotFinite(x, p) else false,
        .array => return itemsNotFinite(&v, p),
        .pointer => |ptr| {
            if (ptr.size != .slice or ptr.child == u8) return false;
            return itemsNotFinite(v, p);
        },
        .@"struct" => |s| {
            const mark = p.len;
            inline for (s.field_names) |field_name| {
                p.len = mark;
                p.push(".{s}", .{field_name});
                if (valueNotFinite(@field(v, field_name), p)) return true;
            }
            p.len = mark;
            return false;
        },
        .@"union" => |u| {
            if (u.tag_type == null) return false;
            switch (v) {
                inline else => |x, tag| {
                    const mark = p.len;
                    p.push(".{s}", .{@tagName(tag)});
                    if (valueNotFinite(x, p)) return true;
                    p.len = mark;
                    return false;
                },
            }
        },
        else => return false,
    }
}

fn itemsNotFinite(items: anytype, p: *NotFinite) bool {
    const mark = p.len;
    for (items, 0..) |x, i| {
        p.len = mark;
        p.push("[{d}]", .{i});
        if (valueNotFinite(x, p)) return true;
    }
    p.len = mark;
    return false;
}

test "a number that is not finite is found with its node and field" {
    var stops = [_]Stop{
        .{
            .at = 0,
            .color = .{},
        },
        .{
            .at = std.math.nan(f32),
            .color = .{},
        },
    };
    var fills = [_]Paint{.{
        .kind = .linear,
        .stops = &stops,
    }};
    var kids = [_]Node{.{
        .id = "1:2",
        .kind = .rectangle,
        .fills = &fills,
    }};
    var pages = [_]Node{.{
        .id = "0:1",
        .kind = .page,
        .children = &kids,
    }};
    var doc: Document = .{
        .arena = .init(std.testing.allocator),
        .pages = &pages,
    };
    defer doc.deinit();
    var buf: [200]u8 = undefined;
    const p = findNotFinite(&doc).?;
    try std.testing.expectEqualStrings("node 1:2: fills[0].stops[1].at is not a finite number", p.describe(&buf));
    stops[1].at = 1;
    try std.testing.expect(findNotFinite(&doc) == null);
    kids[0].size.y = std.math.inf(f32);
    try std.testing.expectEqualStrings("size.y", findNotFinite(&doc).?.field());
}

test "a deep copy shares no memory with the original" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var name = "frame".*;
    var stops = [_]Stop{.{
        .at = 0.5,
        .color = .{},
    }};
    var fills = [_]Paint{.{
        .kind = .linear,
        .stops = &stops,
    }};
    var kids = [_]Node{.{
        .id = "1:2",
        .kind = .rectangle,
        .name = &name,
        .fills = &fills,
        .text = .{
            .text = "hi",
            .style = .{
                .line_height = .{
                    .px = 12,
                },
            },
        },
    }};
    const top: Node = .{
        .id = "0:1",
        .kind = .page,
        .children = &kids,
    };
    const copy = try deepCopy(a, top);
    name[0] = 'X';
    stops[0].at = 2;
    try std.testing.expectEqualStrings("frame", copy.children[0].name);
    try std.testing.expectEqual(@as(f32, 0.5), copy.children[0].fills[0].stops[0].at);
    try std.testing.expect(copy.children.ptr != top.children.ptr);
    try std.testing.expectEqual(@as(f32, 12), copy.children[0].text.?.style.line_height.?.px);
}
