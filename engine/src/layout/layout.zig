//! Layout: the sizes and positions that follow from rules. Auto layout (rows, columns,
//! wrapped rows, grids), hug / fill / fixed sizing with min and max limits, text boxes
//! that size themselves, groups that fit their children, and constraints when a frame
//! changes size.
//!
//! Built from Figma's public help articles (auto layout, constraints, text resizing), its
//! public REST and Plugin API references, and by measuring our own files: every rule that
//! is not in the docs is described in docs/layout.md with the evidence.
//!
//! The model: along each axis a node is `fixed` (its stored size is an input), `hug`s its
//! content, or `fill`s what its auto layout parent leaves. Widths never depend on heights,
//! so a container solves its children's widths first, then their heights (text wraps at
//! its final width). Measuring is pure: `measureWidth` and `measureHeight` lay a subtree
//! out in their heads. `place` then writes sizes and positions top-down. A size that is
//! not a number (NaN) is unknown: constraints then leave the children where they are.

const std = @import("std");
const m = @import("../pubd/model.zig");
const geom = @import("../raster/geom.zig");
const tl = @import("../text/layout.zig");

pub const FontSet = tl.FontSet;
const Vec2 = geom.Vec2;
const Affine = geom.Affine;
const Allocator = std.mem.Allocator;

pub const Options = struct {
    /// Round auto-sized text up to whole pixels, as Figma stores it (docs/layout.md).
    round_text: bool = true,
    /// When set, every node the pass may move or resize is added with its size and
    /// transform before the pass touched it (a node may come more than once: its first
    /// entry holds what it was). An editor compares to learn what changed.
    log: ?*std.ArrayList(Snap) = null,
    /// Layers being dragged in an auto layout (ids): each keeps its place in the flow
    /// and gets its size, but stays where the drag put it.
    held: []const []const u8 = &.{},
    /// The fonts text is measured with; without them, text keeps its stored size.
    fonts: ?*const FontSet = null,
    /// `relayoutFrom` and `relayoutPath`: the node is first resized to it (its children
    /// follow their constraints). Without it, the node keeps its size.
    size: ?Vec2 = null,
};

/// A node's size and transform before a layout pass (`Options.log`).
pub const Snap = struct {
    node: *m.Node,
    size: Vec2,
    transform: Affine,
};

/// What a layout pass did.
pub const Report = struct {
    /// Nodes placed.
    nodes: u32 = 0,
    /// Auto layout frames arranged.
    flows: u32 = 0,
    /// Text boxes measured (layouts run, cached ones not counted).
    texts: u32 = 0,
    /// Auto-sized text boxes that kept their stored size: no fonts, or a face missing.
    unmeasured: u32 = 0,
};

/// How a node sizes along one axis.
pub const Mode = enum {
    /// The stored size is an input.
    fixed,
    /// As big as its content.
    hug,
    /// What its auto layout parent gives it.
    fill,
};

/// Recomputes every rule-determined size and position in the document.
pub fn relayout(gpa: Allocator, doc: *m.Document, options: Options) !Report {
    var ctx: Ctx = .{
        .gpa = gpa,
        .fonts = options.fonts,
        .options = options,
    };
    defer ctx.deinit();
    for (doc.pages) |*page| {
        for (page.children) |*top| try ctx.place(top, try ctx.ownSize(top));
    }
    return ctx.report;
}

/// Recomputes the node `id` after an edit and whatever depends on it: its subtree, and
/// each ancestor whose size follows its content (hugging frames, groups), up to the first
/// one whose size does not change with its content. With `size`, the node is first
/// resized to it (`Options.size`).
pub fn relayoutFrom(gpa: Allocator, doc: *m.Document, id: []const u8, options: Options) !Report {
    var ctx: Ctx = .{
        .gpa = gpa,
        .fonts = options.fonts,
        .options = options,
    };
    defer ctx.deinit();
    var path: std.ArrayList(*m.Node) = .empty;
    defer path.deinit(gpa);
    for (doc.pages) |*page| {
        if (try findPath(gpa, page, id, &path)) break;
    } else return error.NodeNotFound;
    return ctx.fromPath(path.items, options.size);
}

/// `relayoutFrom` for a host that knows where the node is: `path` runs from its page
/// (first) to the node (last).
pub fn relayoutPath(gpa: Allocator, path: []const *m.Node, options: Options) !Report {
    var ctx: Ctx = .{
        .gpa = gpa,
        .fonts = options.fonts,
        .options = options,
    };
    defer ctx.deinit();
    if (path.len == 0) return error.NodeNotFound;
    return ctx.fromPath(path, options.size);
}

/// Lays out `n`'s subtree at `n`'s current size, as `relayout` does for a page's frames.
/// For hosts that build documents: an importer places what a file leaves unknown.
pub fn arrange(gpa: Allocator, n: *m.Node, options: Options) !Report {
    var ctx: Ctx = .{
        .gpa = gpa,
        .fonts = options.fonts,
        .options = options,
    };
    defer ctx.deinit();
    try ctx.place(n, n.size);
    return ctx.report;
}

/// The box a group fits around its children (Figma's group rule): the union of its
/// visible children's boxes, a mask clipping the boxes of the siblings above it. Feed
/// the children bottom-up with the size each has; `result` is null when nothing visible
/// was added.
pub const GroupBox = struct {
    x0: f32 = std.math.inf(f32),
    y0: f32 = std.math.inf(f32),
    x1: f32 = -std.math.inf(f32),
    y1: f32 = -std.math.inf(f32),
    clip: ?[4]f32 = null,

    pub const Box = struct {
        /// The top-left in the group's space.
        min: Vec2,
        size: Vec2,
    };

    pub fn add(g: *GroupBox, c: *const m.Node, s: Vec2) void {
        if (!c.visible) return;
        const o = boxOrigin(c.transform, s);
        const b = boxSize(c.transform, s);
        var r = [4]f32{ o.x, o.y, o.x + b.x, o.y + b.y };
        if (c.mask != null) {
            g.clip = r;
        } else if (g.clip) |k| {
            r = .{ @max(r[0], k[0]), @max(r[1], k[1]), @min(r[2], k[2]), @min(r[3], k[3]) };
            if (r[0] > r[2] or r[1] > r[3]) return;
        }
        g.x0 = @min(g.x0, r[0]);
        g.y0 = @min(g.y0, r[1]);
        g.x1 = @max(g.x1, r[2]);
        g.y1 = @max(g.y1, r[3]);
    }

    pub fn result(g: GroupBox) ?Box {
        if (!(g.x0 <= g.x1)) return null;
        return .{
            .min = .{
                .x = g.x0,
                .y = g.y0,
            },
            .size = .{
                .x = g.x1 - g.x0,
                .y = g.y1 - g.y0,
            },
        };
    }
};

/// A group's box from its children's stored sizes (no measuring); null when no child
/// is visible.
pub fn storedGroupBox(n: *const m.Node) ?GroupBox.Box {
    var g: GroupBox = .{};
    for (n.children) |*c| g.add(c, c.size);
    return g.result();
}

fn findPath(gpa: Allocator, n: *m.Node, id: []const u8, path: *std.ArrayList(*m.Node)) !bool {
    try path.append(gpa, n);
    if (std.mem.eql(u8, n.id, id)) return true;
    for (n.children) |*c| if (try findPath(gpa, c, id, path)) return true;
    _ = path.pop();
    return false;
}

/// True when a child takes part in its parent's auto layout: the parent has one, and the
/// child is visible and not absolutely positioned.
pub fn inFlow(parent: *const m.Node, child: *const m.Node) bool {
    if (parent.layout == null or !parent.kind.isContainer()) return false;
    return child.visible and !child.absolute;
}

/// How `n` sizes along x (`x_axis`) or y. `in_flow`: it sits in an auto layout.
pub fn axisMode(n: *const m.Node, in_flow: bool, x_axis: bool) Mode {
    if (in_flow) if (n.sizing) |s| if ((if (x_axis) s.w else s.h) == .fill) return .fill;
    if (rotated(n)) return .fixed;
    switch (n.kind) {
        .group => return if (n.repeat == null) .hug else .fixed,
        .text => if (n.text) |t| return switch (t.resize) {
            .width_and_height => .hug,
            .height => if (x_axis) .fixed else .hug,
            .fixed, .truncate => .fixed,
        },
        .frame, .component, .component_set, .instance => if (n.layout) |l| {
            return if ((if (x_axis) l.width else l.height) == .hug) .hug else .fixed;
        },
        else => {},
    }
    return .fixed;
}

/// True when some part of a node's size follows its content.
pub fn sizeFollowsContent(n: *const m.Node) bool {
    return axisMode(n, false, true) == .hug or axisMode(n, false, false) == .hug;
}

/// A node turned, skewed or flipped: its box in the parent is not its size.
fn rotated(n: *const m.Node) bool {
    const t = n.transform;
    return @abs(t.b) > 1e-6 or @abs(t.c) > 1e-6 or t.a < 0 or t.d < 0;
}

/// The node's box in its parent's space: its size through the transform's linear part.
pub fn boxSize(t: Affine, s: Vec2) Vec2 {
    return .{
        .x = @abs(t.a) * s.x + @abs(t.c) * s.y,
        .y = @abs(t.b) * s.x + @abs(t.d) * s.y,
    };
}

/// The top-left of the node's box in its parent's space.
pub fn boxOrigin(t: Affine, s: Vec2) Vec2 {
    return .{
        .x = t.e + @min(0, t.a * s.x) + @min(0, t.c * s.y),
        .y = t.f + @min(0, t.b * s.x) + @min(0, t.d * s.y),
    };
}

/// Moves the node so the top-left of its box is `p`.
fn setBoxOrigin(n: *m.Node, s: Vec2, p: Vec2) void {
    const t = n.transform;
    n.transform.e = p.x - @min(0, t.a * s.x) - @min(0, t.c * s.y);
    n.transform.f = p.y - @min(0, t.b * s.x) - @min(0, t.d * s.y);
}

fn clampSize(v: f32, lo: ?f32, hi: ?f32) f32 {
    var r = v;
    if (hi) |h| r = @min(r, h);
    if (lo) |l| r = @max(r, l);
    return r;
}

fn clampW(n: *const m.Node, v: f32) f32 {
    return clampSize(v, n.min_width, n.max_width);
}

fn clampH(n: *const m.Node, v: f32) f32 {
    return clampSize(v, n.min_height, n.max_height);
}

/// The part of a node's stroke outside its box, per side (top, right, bottom, left).
fn strokeOutset(n: *const m.Node) [4]f32 {
    var any = false;
    for (n.strokes) |p| if (p.visible) {
        any = true;
    };
    if (!any) return .{ 0, 0, 0, 0 };
    const k: f32 = switch (n.stroke.alignFor(n.kind)) {
        .inside => 0,
        .center => 0.5,
        .outside => 1,
    };
    const w = n.stroke.sides orelse [4]f32{ n.stroke.weight, n.stroke.weight, n.stroke.weight, n.stroke.weight };
    return .{ w[0] * k, w[1] * k, w[2] * k, w[3] * k };
}

/// The part of a node's stroke inside its box, per side (top, right, bottom, left).
fn strokeInset(n: *const m.Node) [4]f32 {
    var any = false;
    for (n.strokes) |p| if (p.visible) {
        any = true;
    };
    if (!any) return .{ 0, 0, 0, 0 };
    const k: f32 = switch (n.stroke.alignFor(n.kind)) {
        .inside => 1,
        .center => 0.5,
        .outside => 0,
    };
    const w = n.stroke.sides orelse [4]f32{ n.stroke.weight, n.stroke.weight, n.stroke.weight, n.stroke.weight };
    return .{ w[0] * k, w[1] * k, w[2] * k, w[3] * k };
}

/// Lays a text out unwrapped (`width` null) or wrapped at `width`, as auto-sized text is:
/// its natural width and height, unrounded. Null when a face is missing.
pub fn measureText(gpa: Allocator, t: m.Text, width: ?f32, fonts: *const FontSet) !?TextSize {
    var tt = t;
    tt.resize = if (width == null) .width_and_height else .height;
    // Only `maxLines` limits an auto height (there is no box height to fill).
    const big: f32 = 1e7;
    var out = tl.layout(
        gpa,
        &tt,
        .{
            .x = width orelse big,
            .y = big,
        },
        fonts,
        .{},
    ) catch return null;
    defer out.deinit(gpa);
    if (out.missing > 0) return null;
    // The box ends at the last glyph's advance without its letter spacing.
    var ink: f32 = 0;
    for (out.lines.items) |ln| ink = @max(ink, ln.width - ln.trail);
    return .{
        .w = ink,
        .h = out.height,
        .baseline = if (out.lines.items.len > 0) out.lines.items[0].baseline else 0,
        .lines = @intCast(out.lines.items.len),
    };
}

/// A text box as laid out: its width and height, and its first baseline from the top.
pub const TextSize = struct {
    w: f32,
    h: f32,
    baseline: f32,
    lines: u32 = 0,
};

const TextKey = struct {
    node: usize,
    /// The wrap width's bits, or all ones for no wrapping.
    width: u32,
};

/// One child in an auto layout, as the solver sees it.
const Item = struct {
    node: *m.Node,
    mx: Mode,
    my: Mode,
    /// The node's own size (not its box).
    w: f32 = 0,
    h: f32 = 0,
    /// Stroke outset when strokes take space (top, right, bottom, left).
    margin: [4]f32 = .{ 0, 0, 0, 0 },
    turned: bool = false,

    /// Width and height of the box the layout moves (rotation and stroke included).
    fn boxW(it: Item) f32 {
        const b = if (it.turned) boxSize(it.node.transform, .{
            .x = it.w,
            .y = it.h,
        }).x else it.w;
        return b + it.margin[1] + it.margin[3];
    }

    fn boxH(it: Item) f32 {
        const b = if (it.turned) boxSize(it.node.transform, .{
            .x = it.w,
            .y = it.h,
        }).y else it.h;
        return b + it.margin[0] + it.margin[2];
    }
};

const Ctx = struct {
    gpa: Allocator,
    fonts: ?*const FontSet,
    options: Options,
    report: Report = .{},
    texts: std.AutoHashMapUnmanaged(TextKey, ?TextSize) = .empty,

    fn deinit(ctx: *Ctx) void {
        ctx.texts.deinit(ctx.gpa);
    }

    /// `relayoutFrom` along `path` (page first, the node last).
    fn fromPath(ctx: *Ctx, path: []const *m.Node, size: ?Vec2) !Report {
        if (path.len == 1) {
            // A page: everything on it.
            for (path[0].children) |*top| try ctx.place(top, try ctx.ownSize(top));
            return ctx.report;
        }
        // Climb while the current node's size may follow its content and its parent
        // arranges or fits its children.
        var i = path.len - 1;
        var target_size = size;
        while (i >= 2) {
            const cur = path[i];
            const par = path[i - 1];
            const resized = (i == path.len - 1 and size != null);
            if (!resized and !sizeFollowsContent(cur)) break;
            if (!(par.layout != null and par.kind.isContainer()) and par.kind != .group) break;
            if (i == path.len - 1 and size != null) {
                // Apply the requested size first so the parent sees it as fixed.
                try ctx.place(cur, size.?);
                target_size = null;
            }
            i -= 1;
        }
        const root = path[i];
        const parent = path[i - 1];
        const in_flow = inFlow(parent, root);
        const s = target_size orelse if (in_flow or !sizeFollowsContent(root)) root.size else try ctx.ownSize(root);
        try ctx.place(root, s);
        return ctx.report;
    }

    /// Notes `n` and its children as they are before this pass changes them.
    fn note(ctx: *Ctx, n: *m.Node) !void {
        const log = ctx.options.log orelse return;
        try log.append(ctx.gpa, .{
            .node = n,
            .size = n.size,
            .transform = n.transform,
        });
        for (n.children) |*c| try log.append(ctx.gpa, .{
            .node = c,
            .size = c.size,
            .transform = c.transform,
        });
    }

    // ---- text ----

    /// Lays the text out: unwrapped (`width` null) or wrapped at `width`. Null when it
    /// cannot be measured (no fonts, a face missing).
    fn textSize(ctx: *Ctx, n: *const m.Node, width: ?f32) !?TextSize {
        const t = n.text orelse return null;
        const key: TextKey = .{
            .node = @intFromPtr(n),
            .width = if (width) |w| @bitCast(w) else std.math.maxInt(u32),
        };
        if (ctx.texts.get(key)) |v| return v;
        const result = try ctx.layText(t, width);
        try ctx.texts.put(ctx.gpa, key, result);
        if (result == null) ctx.report.unmeasured += 1;
        return result;
    }

    fn layText(ctx: *Ctx, t: m.Text, width: ?f32) !?TextSize {
        const fonts = ctx.fonts orelse return null;
        ctx.report.texts += 1;
        return measureText(ctx.gpa, t, width, fonts);
    }

    /// Figma stores auto-sized text in whole pixels, rounded up (docs/layout.md).
    fn roundText(ctx: *const Ctx, v: f32) f32 {
        if (!ctx.options.round_text) return v;
        return @ceil(v);
    }

    // ---- measuring ----

    /// The width a node takes when it hugs along x.
    fn measureWidth(ctx: *Ctx, n: *m.Node) anyerror!f32 {
        switch (n.kind) {
            .text => {
                const ts = try ctx.textSize(n, null) orelse return n.size.x;
                return clampW(n, ctx.roundText(ts.w));
            },
            .group => return (try ctx.groupBounds(n)).size.x,
            .frame, .component, .component_set, .instance => if (n.layout != null) {
                return (try ctx.flow(n, null, null, false, false)).x;
            },
            else => {},
        }
        return n.size.x;
    }

    /// The height a node takes when it hugs along y at width `w`.
    fn measureHeight(ctx: *Ctx, n: *m.Node, w: f32) anyerror!f32 {
        switch (n.kind) {
            .text => {
                const t = n.text.?;
                const ts = (if (t.resize == .width_and_height and axisMode(n, false, true) == .hug)
                    try ctx.textSize(n, null)
                else
                    try ctx.textSize(n, w)) orelse return n.size.y;
                return clampH(n, ctx.roundText(ts.h));
            },
            .group => return (try ctx.groupBounds(n)).size.y,
            .frame, .component, .component_set, .instance => if (n.layout != null) {
                return (try ctx.flow(n, w, null, true, false)).y;
            },
            else => {},
        }
        return n.size.y;
    }

    /// A node's size by its own rules (not sized by an auto layout parent).
    fn ownSize(ctx: *Ctx, n: *m.Node) anyerror!Vec2 {
        if (n.kind == .group and n.repeat == null) return (try ctx.groupBounds(n)).size;
        const w = if (axisMode(n, false, true) == .hug) try ctx.measureWidth(n) else n.size.x;
        const h = if (axisMode(n, false, false) == .hug) try ctx.measureHeight(n, w) else n.size.y;
        return .{
            .x = w,
            .y = h,
        };
    }

    /// A group's bounds in its own space: the union of its children's boxes, each at its
    /// own size. A mask clips the boxes of the siblings it masks (measured).
    fn groupBounds(ctx: *Ctx, n: *m.Node) anyerror!GroupBox.Box {
        var g: GroupBox = .{};
        for (n.children) |*c| {
            if (!c.visible) continue;
            g.add(c, try ctx.ownSize(c));
        }
        return g.result() orelse .{
            .min = .{},
            .size = n.size,
        };
    }

    // ---- placing ----

    /// Gives `n` its final size and lays out everything inside it.
    fn place(ctx: *Ctx, n: *m.Node, size: Vec2) anyerror!void {
        ctx.report.nodes += 1;
        try ctx.note(n);
        const old = n.size;
        if (n.kind == .group and n.repeat == null) return ctx.placeGroup(n);
        n.size = size;
        if (n.layout != null and n.kind.isContainer()) {
            _ = try ctx.flow(n, size.x, size.y, true, true);
            // Children out of the flow keep to their constraints.
            for (n.children) |*c| if (!inFlow(n, c)) try ctx.placeFree(c, old, size);
            return;
        }
        if (n.kind == .boolean) return;
        for (n.children) |*c| try ctx.placeFree(c, old, size);
    }

    /// A child placed by its constraints: the parent went from `old` to `new`.
    fn placeFree(ctx: *Ctx, c: *m.Node, old: Vec2, new: Vec2) anyerror!void {
        var s = try ctx.ownSize(c);
        const finite = std.math.isFinite(old.x) and std.math.isFinite(old.y);
        if (finite and (old.x != new.x or old.y != new.y)) constrain(c, &s, old, new);
        try ctx.place(c, s);
    }

    /// A group: its children keep their places and the group fits around them.
    fn placeGroup(ctx: *Ctx, n: *m.Node) anyerror!void {
        for (n.children) |*c| try ctx.place(c, try ctx.ownSize(c));
        const b = try ctx.groupBounds(n);
        if (b.min.x != 0 or b.min.y != 0) {
            for (n.children) |*c| {
                c.transform.e -= b.min.x;
                c.transform.f -= b.min.y;
            }
            const t = n.transform;
            n.transform.e += t.a * b.min.x + t.c * b.min.y;
            n.transform.f += t.b * b.min.x + t.d * b.min.y;
        }
        n.size = b.size;
    }

    // ---- auto layout ----

    /// Lays out an auto layout frame's flow. `given_w`, `given_h`: the frame's size where
    /// its parent or its own fixed sizing decides it; null where it hugs. Returns the
    /// frame's size. With `do_place`, writes the children's sizes and positions.
    fn flow(ctx: *Ctx, n: *m.Node, given_w: ?f32, given_h: ?f32, need_h: bool, do_place: bool) anyerror!Vec2 {
        const l = n.layout.?;
        // A fixed axis is the stored size even when measuring.
        const gw = given_w orelse if (l.width == .fixed) n.size.x else null;
        const gh = given_h orelse if (l.height == .fixed) n.size.y else null;

        var items: std.ArrayList(Item) = .empty;
        defer items.deinit(ctx.gpa);
        for (n.children) |*c| {
            if (!inFlow(n, c)) continue;
            try items.append(ctx.gpa, .{
                .node = c,
                .mx = axisMode(c, true, true),
                .my = axisMode(c, true, false),
                .w = c.size.x,
                .h = c.size.y,
                .margin = if (l.strokes_included) strokeOutset(c) else .{ 0, 0, 0, 0 },
                .turned = rotated(c),
            });
        }
        var pad = l.padding;
        if (l.strokes_included) {
            const ins = strokeInset(n);
            for (&pad, ins) |*p, s| p.* += s;
        }
        const pad_x = pad[1] + pad[3];
        const pad_y = pad[0] + pad[2];

        if (do_place) ctx.report.flows += 1;
        return switch (l.mode) {
            .horizontal, .vertical => if (l.wrap)
                ctx.flowWrap(n, l, items.items, pad, pad_x, pad_y, gw, gh, need_h, do_place)
            else
                ctx.flowLine(n, l, items.items, pad, pad_x, pad_y, gw, gh, need_h, do_place),
            .grid => ctx.flowGrid(n, l, items.items, pad, pad_x, pad_y, gw, gh, need_h, do_place),
        };
    }

    /// One row or column.
    fn flowLine(ctx: *Ctx, n: *m.Node, l: m.Layout, items: []Item, pad: [4]f32, pad_x: f32, pad_y: f32, gw: ?f32, gh: ?f32, need_h: bool, do_place: bool) anyerror!Vec2 {
        const horizontal = l.mode == .horizontal;
        const count: f32 = @floatFromInt(items.len);
        const gaps: f32 = if (items.len > 1) l.gap * (count - 1) else 0;
        // An auto gap sizes nothing: fill children take the space first.
        const main_gaps: f32 = if (isSpread(l.main)) 0 else gaps;

        // Widths.
        var fills_x: usize = 0;
        for (items) |*it| switch (it.mx) {
            .fixed => {},
            .hug => it.w = try ctx.measureWidth(it.node),
            .fill => fills_x += 1,
        };
        var width: f32 = undefined;
        if (horizontal) {
            if (gw) |w| {
                if (fills_x > 0) distribute(items, true, w - pad_x - main_gaps);
                width = w;
            } else {
                // A hugging row: fill children hug too.
                for (items) |*it| if (it.mx == .fill) {
                    it.w = try ctx.measureWidth(it.node);
                };
                var sum: f32 = 0;
                for (items) |it| sum += it.boxW();
                width = clampW(n, sum + gaps + pad_x);
            }
        } else {
            if (gw) |w| {
                width = w;
            } else {
                var widest: f32 = 0;
                var any = false;
                for (items) |it| if (it.mx != .fill) {
                    widest = @max(widest, it.boxW());
                    any = true;
                };
                if (!any) for (items) |*it| {
                    widest = @max(widest, try ctx.measureWidth(it.node));
                };
                width = clampW(n, widest + pad_x);
            }
            const inner = width - pad_x;
            for (items) |*it| if (it.mx == .fill) {
                it.w = clampW(it.node, inner - it.margin[1] - it.margin[3]);
            };
        }
        if (!need_h and !do_place) return .{
            .x = width,
            .y = n.size.y,
        };

        // Heights.
        var fills_y: usize = 0;
        for (items) |*it| switch (it.my) {
            .fixed => {},
            .hug => it.h = try ctx.measureHeight(it.node, it.w),
            .fill => fills_y += 1,
        };
        var height: f32 = undefined;
        if (!horizontal) {
            if (gh) |h| {
                if (fills_y > 0) distribute(items, false, h - pad_y - main_gaps);
                height = h;
            } else {
                for (items) |*it| if (it.my == .fill) {
                    it.h = try ctx.measureHeight(it.node, it.w);
                };
                var sum: f32 = 0;
                for (items) |it| sum += it.boxH();
                height = clampH(n, sum + gaps + pad_y);
            }
        } else {
            if (gh) |h| {
                height = h;
            } else {
                var tallest: f32 = 0;
                var any = false;
                if (l.cross == .baseline) {
                    const b = try ctx.baselineSpan(items);
                    tallest = b.extent;
                    any = true;
                } else for (items) |it| if (it.my != .fill) {
                    tallest = @max(tallest, it.boxH());
                    any = true;
                };
                if (!any) for (items) |*it| {
                    tallest = @max(tallest, try ctx.measureHeight(it.node, it.w));
                };
                height = clampH(n, tallest + pad_y);
            }
            const inner = height - pad_y;
            for (items) |*it| if (it.my == .fill) {
                it.h = clampH(it.node, inner - it.margin[0] - it.margin[2]);
            };
        }
        const size: Vec2 = .{
            .x = width,
            .y = height,
        };
        if (!do_place) return size;

        // Positions.
        const inner_main = if (horizontal) width - pad_x else height - pad_y;
        var used: f32 = 0;
        for (items) |it| used += if (horizontal) it.boxW() else it.boxH();
        const sp = spread(l.main, inner_main - used - gaps, inner_main - used, items.len, l.gap);
        var at = (if (horizontal) pad[3] else pad[0]) + sp.offset;
        const inner_cross = if (horizontal) height - pad_y else width - pad_x;
        const base = if (horizontal and l.cross == .baseline) try ctx.baselineSpan(items) else BaselineSpan{};
        for (items) |*it| {
            const bw = it.boxW();
            const bh = it.boxH();
            const cross_size = if (horizontal) bh else bw;
            const cross_start = if (horizontal) pad[0] else pad[3];
            const cmode = if (horizontal) it.my else it.mx;
            var c: f32 = cross_start;
            // A fill child held short by its max size aligns like any other.
            switch (l.cross) {
                .start => {},
                .center => c += (inner_cross - cross_size) / 2,
                .end => c += inner_cross - cross_size,
                .baseline => if (horizontal and cmode != .fill) {
                    c += base.top - (try ctx.baselineOf(it.*) orelse bh);
                },
            }
            const p: Vec2 = if (horizontal) .{
                .x = at + it.margin[3],
                .y = c + it.margin[0],
            } else .{
                .x = c + it.margin[3],
                .y = at + it.margin[0],
            };
            try ctx.placeItem(it.*, p);
            at += (if (horizontal) bw else bh) + sp.gap;
        }
        return size;
    }

    /// Writes an item's size and box position, then lays out inside it.
    fn placeItem(ctx: *Ctx, it: Item, p: Vec2) anyerror!void {
        const s: Vec2 = .{
            .x = it.w,
            .y = it.h,
        };
        if (!ctx.held(it.node)) setBoxOrigin(it.node, s, p);
        try ctx.place(it.node, s);
    }

    fn held(ctx: *const Ctx, n: *const m.Node) bool {
        for (ctx.options.held) |id| if (std.mem.eql(u8, id, n.id)) return true;
        return false;
    }

    const BaselineSpan = struct {
        /// The shared baseline, from the top of the tallest reach above it.
        top: f32 = 0,
        /// From the highest top to the lowest bottom once aligned.
        extent: f32 = 0,
    };

    /// Children aligned on their first baselines: where the baseline sits and how tall
    /// the row is. A child without text aligns its bottom edge.
    fn baselineSpan(ctx: *Ctx, items: []const Item) anyerror!BaselineSpan {
        var above: f32 = 0;
        var below: f32 = 0;
        for (items) |it| {
            const bh = it.boxH();
            const b = try ctx.baselineOf(it) orelse bh;
            above = @max(above, b);
            below = @max(below, bh - b);
        }
        return .{
            .top = above,
            .extent = above + below,
        };
    }

    /// An item's first baseline from the top of its box, if it has one: a text's first
    /// line, an auto layout frame's first child with one (assumed, docs/layout.md).
    fn baselineOf(ctx: *Ctx, it: Item) anyerror!?f32 {
        const n = it.node;
        switch (n.kind) {
            .text => {
                const t = n.text.?;
                const fonts = ctx.fonts orelse return null;
                var out = tl.layout(
                    ctx.gpa,
                    &t,
                    .{
                        .x = it.w,
                        .y = it.h,
                    },
                    fonts,
                    .{},
                ) catch return null;
                defer out.deinit(ctx.gpa);
                if (out.lines.items.len == 0) return null;
                return out.lines.items[0].baseline + it.margin[0];
            },
            .frame, .component, .component_set, .instance => {
                // An auto layout frame aligns by its first child that has a baseline (laid
                // out at this size to find where that child sits).
                if (n.layout == null or rotated(n)) return null;
                try ctx.place(n, .{
                    .x = it.w,
                    .y = it.h,
                });
                for (n.children) |*c| {
                    if (!inFlow(n, c) or rotated(c)) continue;
                    const sub: Item = .{
                        .node = c,
                        .mx = .fixed,
                        .my = .fixed,
                        .w = c.size.x,
                        .h = c.size.y,
                    };
                    if (try ctx.baselineOf(sub)) |b| return c.transform.f + b + it.margin[0];
                }
                return null;
            },
            else => return null,
        }
    }

    /// Wrapped rows (or, in a vertical layout, wrapped columns): children fill a line
    /// along the main axis until the next does not fit, lines stack across it.
    fn flowWrap(ctx: *Ctx, n: *m.Node, l: m.Layout, items: []Item, pad: [4]f32, pad_x: f32, pad_y: f32, gw: ?f32, gh: ?f32, need_h: bool, do_place: bool) anyerror!Vec2 {
        const horizontal = l.mode == .horizontal;
        for (items) |*it| if (it.mx != .fixed) {
            it.w = try ctx.measureWidth(it.node);
        };
        const count: f32 = @floatFromInt(items.len);
        const main_gaps: f32 = if (items.len > 1) l.gap * (count - 1) else 0;
        if (horizontal and !need_h and !do_place) {
            if (gw) |w| return .{
                .x = w,
                .y = n.size.y,
            };
            var sum: f32 = 0;
            for (items) |it| sum += it.boxW();
            return .{
                .x = clampW(n, sum + main_gaps + pad_x),
                .y = n.size.y,
            };
        }
        for (items) |*it| if (it.my != .fixed) {
            it.h = try ctx.measureHeight(it.node, it.w);
        };
        // The main axis: given, or one line when the frame hugs it.
        var main_size: ?f32 = if (horizontal) gw else gh;
        if (main_size == null) {
            var sum: f32 = 0;
            for (items) |it| sum += mainOf(it, horizontal);
            main_size = if (horizontal) clampW(n, sum + main_gaps + pad_x) else clampH(n, sum + main_gaps + pad_y);
        }
        const inner_main = main_size.? - (if (horizontal) pad_x else pad_y);

        // Break into lines.
        var lines: std.ArrayList([2]usize) = .empty;
        defer lines.deinit(ctx.gpa);
        var line_cross: std.ArrayList(f32) = .empty;
        defer line_cross.deinit(ctx.gpa);
        var start: usize = 0;
        while (start < items.len) {
            var end = start + 1;
            var run = mainOf(items[start], horizontal);
            while (end < items.len and run + l.gap + mainOf(items[end], horizontal) <= inner_main + 0.01) : (end += 1) run += l.gap + mainOf(items[end], horizontal);
            var thickest: f32 = 0;
            for (items[start..end]) |it| thickest = @max(thickest, crossOf(it, horizontal));
            try lines.append(ctx.gpa, .{ start, end });
            try line_cross.append(ctx.gpa, thickest);
            start = end;
        }
        var sum_cross: f32 = 0;
        for (line_cross.items) |c| sum_cross += c;
        const nl: f32 = @floatFromInt(lines.items.len);
        const cross_gaps = if (lines.items.len > 1) l.cross_gap * (nl - 1) else 0;
        const size: Vec2 = if (horizontal) .{
            .x = main_size.?,
            .y = gh orelse clampH(n, sum_cross + cross_gaps + pad_y),
        } else .{
            .x = gw orelse clampW(n, sum_cross + cross_gaps + pad_x),
            .y = main_size.?,
        };
        if (!do_place) return size;

        const inner_cross = if (horizontal) size.y - pad_y else size.x - pad_x;
        var line_gap = l.cross_gap;
        var at_cross = if (horizontal) pad[0] else pad[3];
        if (l.align_content == .space_between and lines.items.len > 1) {
            line_gap = (inner_cross - sum_cross) / (nl - 1);
        } else switch (l.cross) {
            .center => at_cross += (inner_cross - sum_cross - cross_gaps) / 2,
            .end => at_cross += inner_cross - sum_cross - cross_gaps,
            else => {},
        }
        for (lines.items, line_cross.items) |r, lc| {
            const row = items[r[0]..r[1]];
            var used: f32 = 0;
            for (row) |it| used += mainOf(it, horizontal);
            const rc: f32 = @floatFromInt(row.len);
            const gaps = if (row.len > 1) l.gap * (rc - 1) else 0;
            const sp = spread(l.main, inner_main - used - gaps, inner_main - used, row.len, l.gap);
            var at_main = (if (horizontal) pad[3] else pad[0]) + sp.offset;
            for (row) |*it| {
                var c = at_cross;
                const cs = crossOf(it.*, horizontal);
                switch (l.cross) {
                    .center => c += (lc - cs) / 2,
                    .end => c += lc - cs,
                    else => {},
                }
                try ctx.placeItem(it.*, if (horizontal) .{
                    .x = at_main + it.margin[3],
                    .y = c + it.margin[0],
                } else .{
                    .x = c + it.margin[3],
                    .y = at_main + it.margin[0],
                });
                at_main += mainOf(it.*, horizontal) + sp.gap;
            }
            at_cross += lc + line_gap;
        }
        return size;
    }

    /// A grid: column widths, then row heights, then each child in its cell area.
    fn flowGrid(ctx: *Ctx, n: *m.Node, l: m.Layout, items: []Item, pad: [4]f32, pad_x: f32, pad_y: f32, gw: ?f32, gh: ?f32, need_h: bool, do_place: bool) anyerror!Vec2 {
        const one = [_]m.Track{.{}};
        const cols = if (l.columns.len > 0) l.columns else &one;
        const rows = if (l.rows.len > 0) l.rows else &one;
        const cw = try ctx.gpa.alloc(f32, cols.len);
        defer ctx.gpa.free(cw);
        const rh = try ctx.gpa.alloc(f32, rows.len);
        defer ctx.gpa.free(rh);

        for (items) |*it| if (it.mx == .hug) {
            it.w = try ctx.measureWidth(it.node);
        };
        // Column widths: fixed, hugging the widest single-column child, flexible shares.
        try ctx.tracks(cols, cw, items, true, if (gw) |w| w - pad_x else null, l.gap);
        const width = gw orelse clampW(n, total(cw) + gapsOf(cols.len, l.gap) + pad_x);
        for (items) |*it| if (it.mx == .fill) {
            const a = area(cw, cellOf(it.node, true), l.gap);
            it.w = clampW(it.node, a.size - it.margin[1] - it.margin[3]);
        };
        if (!need_h and !do_place) return .{
            .x = width,
            .y = n.size.y,
        };
        for (items) |*it| if (it.my == .hug) {
            it.h = try ctx.measureHeight(it.node, it.w);
        };
        try ctx.tracks(rows, rh, items, false, if (gh) |h| h - pad_y else null, l.cross_gap);
        const height = gh orelse clampH(n, total(rh) + gapsOf(rows.len, l.cross_gap) + pad_y);
        const size: Vec2 = .{
            .x = width,
            .y = height,
        };
        if (!do_place) return size;
        for (items) |*it| {
            const ax = area(cw, cellOf(it.node, true), l.gap);
            const ay = area(rh, cellOf(it.node, false), l.cross_gap);
            if (it.my == .fill) it.h = clampH(it.node, ay.size - it.margin[0] - it.margin[2]);
            const cell = it.node.cell orelse m.Cell{};
            const x = alignIn(ax.start, ax.size, it.boxW(), if (it.mx == .fill) .start else cell.h);
            const y = alignIn(ay.start, ay.size, it.boxH(), if (it.my == .fill) .start else cell.v);
            try ctx.placeItem(it.*, .{
                .x = pad[3] + x + it.margin[3],
                .y = pad[0] + y + it.margin[0],
            });
        }
        return size;
    }

    /// Sizes grid tracks along one axis. `inner`: the space for tracks and gaps, null when
    /// the grid hugs (flexible tracks then hug too).
    fn tracks(ctx: *Ctx, list: []const m.Track, out: []f32, items: []const Item, x_axis: bool, inner: ?f32, gap: f32) !void {
        _ = ctx;
        var fixed_total: f32 = 0;
        var flex_total: f32 = 0;
        for (list, out, 0..) |t, *o, i| {
            o.* = 0;
            const hugs = t.kind == .hug or (t.kind == .flex and inner == null);
            if (t.kind == .fixed) o.* = t.value;
            if (hugs) for (items) |it| {
                const c = cellOf(it.node, x_axis);
                if (c.start != i or c.span != 1) continue;
                const mode = if (x_axis) it.mx else it.my;
                if (mode == .fill) continue;
                o.* = @max(o.*, if (x_axis) it.boxW() else it.boxH());
            };
            if (t.kind == .flex and inner != null) flex_total += @max(t.value, 0) else fixed_total += o.*;
        }
        if (inner) |space| if (flex_total > 0) {
            const free = @max(0, space - fixed_total - gapsOf(list.len, gap));
            for (list, out) |t, *o| if (t.kind == .flex) {
                o.* = free * @max(t.value, 0) / flex_total;
            };
        };
    }
};

fn mainOf(it: Item, horizontal: bool) f32 {
    return if (horizontal) it.boxW() else it.boxH();
}

fn crossOf(it: Item, horizontal: bool) f32 {
    return if (horizontal) it.boxH() else it.boxW();
}

fn total(xs: []const f32) f32 {
    var s: f32 = 0;
    for (xs) |x| s += x;
    return s;
}

fn gapsOf(count: usize, gap: f32) f32 {
    return if (count > 1) gap * @as(f32, @floatFromInt(count - 1)) else 0;
}

const Span = struct {
    start: usize,
    span: usize,
};

fn cellOf(n: *const m.Node, x_axis: bool) Span {
    const c = n.cell orelse m.Cell{};
    return if (x_axis) .{
        .start = c.column,
        .span = @max(1, c.column_span),
    } else .{
        .start = c.row,
        .span = @max(1, c.row_span),
    };
}

/// Where a cell area starts and how big it is along one axis.
fn area(sizes: []const f32, c: Span, gap: f32) struct {
    start: f32,
    size: f32,
} {
    const first = @min(c.start, sizes.len - 1);
    const last = @min(first + c.span, sizes.len);
    var start: f32 = 0;
    for (sizes[0..first]) |s| start += s + gap;
    var size: f32 = 0;
    for (sizes[first..last]) |s| size += s;
    size += gapsOf(last - first, gap);
    return .{
        .start = start,
        .size = size,
    };
}

fn alignIn(start: f32, space: f32, size: f32, a: m.CellAlign) f32 {
    return switch (a) {
        .auto, .start => start,
        .center => start + (space - size) / 2,
        .end => start + space - size,
    };
}

fn isSpread(a: m.MainAlign) bool {
    return a == .space_between or a == .space_around or a == .space_evenly;
}

/// Where the first child starts along the main axis and the gap after each child.
/// `free`: the space left with fixed gaps; `free_no_gaps`: left by the children alone.
fn spread(a: m.MainAlign, free: f32, free_no_gaps: f32, count: usize, gap: f32) struct {
    offset: f32,
    gap: f32,
} {
    const n: f32 = @floatFromInt(count);
    return switch (a) {
        .start => .{
            .offset = 0,
            .gap = gap,
        },
        .center => .{
            .offset = free / 2,
            .gap = gap,
        },
        .end => .{
            .offset = free,
            .gap = gap,
        },
        .space_between => if (count > 1) .{
            .offset = 0,
            .gap = free_no_gaps / (n - 1),
        } else .{
            .offset = 0,
            .gap = 0,
        },
        .space_around => .{
            .offset = free_no_gaps / n / 2,
            .gap = free_no_gaps / n,
        },
        .space_evenly => .{
            .offset = free_no_gaps / (n + 1),
            .gap = free_no_gaps / (n + 1),
        },
    };
}

/// A fill child's starting size along an axis before it shares the free space: its own
/// padding (and the stroke its layout counts). Figma's fill works like CSS `flex: 1 1 0`
/// with border-box sizing: the content boxes share the space, padding comes on top
/// (measured: docs/layout.md).
fn fillBasis(n: *const m.Node, x_axis: bool) f32 {
    const l = n.layout orelse return 0;
    if (!n.kind.isContainer()) return 0;
    var b = if (x_axis) l.padding[1] + l.padding[3] else l.padding[0] + l.padding[2];
    if (l.strokes_included) {
        const ins = strokeInset(n);
        b += if (x_axis) ins[1] + ins[3] else ins[0] + ins[2];
    }
    return b;
}

/// Shares `space` among the fill items along an axis (minus what the other items take),
/// each starting from its basis and clamped by its min and max: a clamped item keeps its
/// clamp and the rest share again (as CSS flexbox does).
fn distribute(items: []Item, x_axis: bool, space: f32) void {
    var free = space;
    var open: usize = 0;
    for (items) |*it| {
        const mode = if (x_axis) it.mx else it.my;
        if (mode == .fill) {
            open += 1;
            free -= fillBasis(it.node, x_axis);
            if (x_axis) it.w = std.math.nan(f32) else it.h = std.math.nan(f32);
        } else free -= if (x_axis) it.boxW() else it.boxH();
    }
    // Frozen items get a number; open ones stay NaN until the last round.
    var rounds: usize = 0;
    while (open > 0 and rounds <= items.len) : (rounds += 1) {
        const share = free / @as(f32, @floatFromInt(open));
        var froze = false;
        for (items) |*it| {
            const mode = if (x_axis) it.mx else it.my;
            const cur = if (x_axis) it.w else it.h;
            if (mode != .fill or !std.math.isNan(cur)) continue;
            const margin = if (x_axis) it.margin[1] + it.margin[3] else it.margin[0] + it.margin[2];
            const basis = fillBasis(it.node, x_axis);
            const want = basis + share - margin;
            const got = if (x_axis) clampW(it.node, want) else clampH(it.node, want);
            if (got != want) {
                if (x_axis) it.w = got else it.h = got;
                free -= got + margin - basis;
                open -= 1;
                froze = true;
            }
        }
        if (!froze) {
            for (items) |*it| {
                const mode = if (x_axis) it.mx else it.my;
                const cur = if (x_axis) it.w else it.h;
                if (mode != .fill or !std.math.isNan(cur)) continue;
                const margin = if (x_axis) it.margin[1] + it.margin[3] else it.margin[0] + it.margin[2];
                const v = fillBasis(it.node, x_axis) + share - margin;
                if (x_axis) it.w = v else it.h = v;
            }
            break;
        }
    }
}

/// Moves and resizes a child for its parent going from `old` to `new`; `s` is the
/// child's size, changed where the constraints stretch or scale it.
pub fn constrain(c: *m.Node, s: *Vec2, old: Vec2, new: Vec2) void {
    const o = boxOrigin(c.transform, s.*);
    const b = boxSize(c.transform, s.*);
    var x = o.x;
    var y = o.y;
    var bw = b.x;
    var bh = b.y;
    const dx = new.x - old.x;
    const dy = new.y - old.y;
    // Centred children keep their offset from a centre placed in whole pixels (rounded
    // down, as Figma centres): measured 145 -> 180 wide moves a 45 wide child 17 px.
    switch (c.constraints.h) {
        .left => {},
        .right => x += dx,
        .center => x += @floor((new.x - bw) / 2) - @floor((old.x - bw) / 2),
        .left_right => bw += dx,
        .scale => if (old.x != 0) {
            const k = new.x / old.x;
            x *= k;
            bw *= k;
        },
    }
    switch (c.constraints.v) {
        .top => {},
        .bottom => y += dy,
        .center => y += @floor((new.y - bh) / 2) - @floor((old.y - bh) / 2),
        .top_bottom => bh += dy,
        .scale => if (old.y != 0) {
            const k = new.y / old.y;
            y *= k;
            bh *= k;
        },
    }
    // Only an unturned child changes size (a turned one moves).
    if (!rotated(c)) {
        if (axisMode(c, false, true) == .fixed) s.x = @max(0, bw);
        if (axisMode(c, false, false) == .fixed) s.y = @max(0, bh);
    }
    setBoxOrigin(c, s.*, .{
        .x = x,
        .y = y,
    });
}

// ---- tests ----

const testing = std.testing;

fn frame(id: []const u8, w: f32, h: f32) m.Node {
    return .{
        .id = id,
        .kind = .frame,
        .size = .{
            .x = w,
            .y = h,
        },
    };
}

fn testDoc(top: m.Node) !m.Document {
    var doc: m.Document = .{
        .arena = .init(testing.allocator),
    };
    const a = doc.arena.allocator();
    const pages = try a.alloc(m.Node, 1);
    const kids = try a.alloc(m.Node, 1);
    kids[0] = top;
    pages[0] = .{
        .id = "0:0",
        .kind = .page,
        .children = kids,
    };
    doc.pages = pages;
    return doc;
}

test "a hugging row: children side by side, gaps and padding" {
    var kids = [_]m.Node{ frame("a", 10, 20), frame("b", 30, 5) };
    var f = frame("f", 0, 0);
    f.layout = .{
        .mode = .horizontal,
        .gap = 4,
        .padding = .{ 1, 2, 3, 4 },
        .cross = .center,
        .width = .hug,
        .height = .hug,
    };
    f.children = &kids;
    var doc = try testDoc(f);
    defer doc.deinit();
    _ = try relayout(testing.allocator, &doc, .{});
    const r = doc.pages[0].children[0];
    try testing.expectEqual(@as(f32, 4 + 10 + 4 + 30 + 2), r.size.x);
    try testing.expectEqual(@as(f32, 1 + 20 + 3), r.size.y);
    try testing.expectEqual(@as(f32, 4), r.children[0].transform.e);
    try testing.expectEqual(@as(f32, 18), r.children[1].transform.e);
    try testing.expectEqual(@as(f32, 1 + 7.5), r.children[1].transform.f);
}

test "fill children share what is left, within their limits" {
    var kids = [_]m.Node{ frame("a", 10, 10), frame("b", 0, 10), frame("c", 0, 10) };
    kids[1].sizing = .{
        .w = .fill,
    };
    kids[2].sizing = .{
        .w = .fill,
    };
    kids[2].max_width = 20;
    var f = frame("f", 100, 10);
    f.layout = .{
        .mode = .horizontal,
        .gap = 5,
    };
    f.children = &kids;
    var doc = try testDoc(f);
    defer doc.deinit();
    _ = try relayout(testing.allocator, &doc, .{});
    const r = doc.pages[0].children[0];
    // 100 - 10 - 2 * 5 = 80; c stops at 20, b takes 60.
    try testing.expectEqual(@as(f32, 60), r.children[1].size.x);
    try testing.expectEqual(@as(f32, 20), r.children[2].size.x);
    try testing.expectEqual(@as(f32, 80), r.children[2].transform.e);
}

test "a fill child held at its max width keeps to the cross alignment" {
    var kids = [_]m.Node{frame("a", 0, 10)};
    kids[0].sizing = .{
        .w = .fill,
    };
    kids[0].max_width = 1280;
    var f = frame("f", 1440, 10);
    f.layout = .{
        .mode = .vertical,
        .cross = .center,
    };
    f.children = &kids;
    var doc = try testDoc(f);
    defer doc.deinit();
    _ = try relayout(testing.allocator, &doc, .{});
    const r = doc.pages[0].children[0];
    try testing.expectEqual(@as(f32, 1280), r.children[0].size.x);
    try testing.expectEqual(@as(f32, 80), r.children[0].transform.e);
}

test "a held child keeps its slot and its place" {
    var kids = [_]m.Node{ frame("a", 10, 10), frame("b", 10, 20), frame("c", 10, 10) };
    kids[1].transform.e = 300;
    kids[1].transform.f = 400;
    var f = frame("f", 0, 0);
    f.layout = .{
        .mode = .vertical,
        .width = .hug,
        .height = .hug,
    };
    f.children = &kids;
    var doc = try testDoc(f);
    defer doc.deinit();
    _ = try relayout(testing.allocator, &doc, .{
        .held = &.{"b"},
    });
    const r = doc.pages[0].children[0];
    try testing.expectEqual(@as(f32, 40), r.size.y);
    try testing.expectEqual(@as(f32, 300), r.children[1].transform.e);
    try testing.expectEqual(@as(f32, 400), r.children[1].transform.f);
    try testing.expectEqual(@as(f32, 30), r.children[2].transform.f);
}

test "space between, around and evenly" {
    const between = spread(.space_between, 0, 30, 4, 0);
    try testing.expectEqual(@as(f32, 10), between.gap);
    const around = spread(.space_around, 0, 30, 3, 0);
    try testing.expectEqual(@as(f32, 5), around.offset);
    try testing.expectEqual(@as(f32, 10), around.gap);
    const evenly = spread(.space_evenly, 0, 30, 2, 0);
    try testing.expectEqual(@as(f32, 10), evenly.offset);
}

test "a vertical stack stretches fill children across and stacks them" {
    var kids = [_]m.Node{ frame("a", 50, 10), frame("b", 0, 20) };
    kids[1].sizing = .{
        .w = .fill,
    };
    var f = frame("f", 0, 0);
    f.layout = .{
        .mode = .vertical,
        .gap = 2,
        .width = .hug,
        .height = .hug,
    };
    f.children = &kids;
    var doc = try testDoc(f);
    defer doc.deinit();
    _ = try relayout(testing.allocator, &doc, .{});
    const r = doc.pages[0].children[0];
    try testing.expectEqual(@as(f32, 50), r.size.x);
    try testing.expectEqual(@as(f32, 32), r.size.y);
    try testing.expectEqual(@as(f32, 50), r.children[1].size.x);
    try testing.expectEqual(@as(f32, 12), r.children[1].transform.f);
}

test "grid tracks: fixed, flexible shares and spans" {
    var kids = [_]m.Node{ frame("a", 10, 10), frame("b", 10, 10) };
    kids[0].cell = .{
        .column = 1,
        .h = .center,
    };
    kids[1].cell = .{
        .column = 0,
        .row = 1,
        .column_span = 2,
        .h = .end,
    };
    var cols = [_]m.Track{ .{
        .kind = .fixed,
        .value = 40,
    }, .{} };
    var rows = [_]m.Track{ .{
        .kind = .fixed,
        .value = 20,
    }, .{
        .kind = .fixed,
        .value = 20,
    } };
    var f = frame("f", 100, 50);
    f.layout = .{
        .mode = .grid,
        .gap = 10,
        .cross_gap = 4,
        .columns = &cols,
        .rows = &rows,
    };
    f.children = &kids;
    var doc = try testDoc(f);
    defer doc.deinit();
    _ = try relayout(testing.allocator, &doc, .{});
    const r = doc.pages[0].children[0];
    // The flexible column is 100 - 40 - 10 = 50 wide, starting at 50.
    try testing.expectEqual(@as(f32, 50 + 20), r.children[0].transform.e);
    try testing.expectEqual(@as(f32, 90), r.children[1].transform.e);
    try testing.expectEqual(@as(f32, 24), r.children[1].transform.f);
}

test "wrapped rows break when the next child does not fit" {
    var kids = [_]m.Node{ frame("a", 40, 10), frame("b", 40, 20), frame("c", 40, 10) };
    var f = frame("f", 100, 0);
    f.layout = .{
        .mode = .horizontal,
        .wrap = true,
        .gap = 10,
        .cross_gap = 5,
        .height = .hug,
    };
    f.children = &kids;
    var doc = try testDoc(f);
    defer doc.deinit();
    _ = try relayout(testing.allocator, &doc, .{});
    const r = doc.pages[0].children[0];
    try testing.expectEqual(@as(f32, 20 + 5 + 10), r.size.y);
    try testing.expectEqual(@as(f32, 0), r.children[2].transform.e);
    try testing.expectEqual(@as(f32, 25), r.children[2].transform.f);
}

test "wrapped columns in a vertical layout" {
    var kids = [_]m.Node{ frame("a", 10, 40), frame("b", 20, 40), frame("c", 10, 40) };
    var f = frame("f", 0, 100);
    f.layout = .{
        .mode = .vertical,
        .wrap = true,
        .gap = 10,
        .cross_gap = 5,
        .width = .hug,
    };
    f.children = &kids;
    var doc = try testDoc(f);
    defer doc.deinit();
    _ = try relayout(testing.allocator, &doc, .{});
    const r = doc.pages[0].children[0];
    try testing.expectEqual(@as(f32, 20 + 5 + 10), r.size.x);
    try testing.expectEqual(@as(f32, 25), r.children[2].transform.e);
    try testing.expectEqual(@as(f32, 0), r.children[2].transform.f);
}

test "constraints follow a parent's resize" {
    var c: m.Node = frame("c", 10, 10);
    c.transform = .translate(20, 30);
    var s: Vec2 = c.size;
    c.constraints = .{
        .h = .right,
        .v = .top_bottom,
    };
    constrain(&c, &s, .{
        .x = 100,
        .y = 100,
    }, .{
        .x = 150,
        .y = 80,
    });
    try testing.expectEqual(@as(f32, 70), c.transform.e);
    try testing.expectEqual(@as(f32, 30), c.transform.f);
    try testing.expectEqual(@as(f32, 0), s.y);
}

test "constraints: Figma's own resize of a 145 x 100 frame to 180 x 126" {
    // Measured in corpus/features (Demo / <h> × <v>): a 45 x 40 child at (20, 20).
    const H = m.HConstraint;
    const V = m.VConstraint;
    const cases = [_]struct {
        h: H,
        v: V,
        want: [4]f32,
    }{
        .{
            .h = .left,
            .v = .top,
            .want = .{ 20, 20, 45, 40 },
        },
        .{
            .h = .center,
            .v = .center,
            .want = .{ 37, 33, 45, 40 },
        },
        .{
            .h = .right,
            .v = .bottom,
            .want = .{ 55, 46, 45, 40 },
        },
        .{
            .h = .left_right,
            .v = .top_bottom,
            .want = .{ 20, 20, 80, 66 },
        },
        .{
            .h = .scale,
            .v = .scale,
            .want = .{ 24.827587, 25.2, 55.862068, 50.4 },
        },
    };
    for (cases) |k| {
        var c = frame("c", 45, 40);
        c.kind = .rectangle;
        c.transform = .translate(20, 20);
        c.constraints = .{
            .h = k.h,
            .v = k.v,
        };
        var s = c.size;
        constrain(&c, &s, .{
            .x = 145,
            .y = 100,
        }, .{
            .x = 180,
            .y = 126,
        });
        try testing.expectApproxEqAbs(k.want[0], c.transform.e, 1e-3);
        try testing.expectApproxEqAbs(k.want[1], c.transform.f, 1e-3);
        try testing.expectApproxEqAbs(k.want[2], s.x, 1e-3);
        try testing.expectApproxEqAbs(k.want[3], s.y, 1e-3);
    }
}

test "a group fits its children and keeps them in place" {
    var kids = [_]m.Node{ frame("a", 10, 10), frame("b", 10, 10) };
    kids[0].kind = .rectangle;
    kids[1].kind = .rectangle;
    kids[0].transform = .translate(5, 5);
    kids[1].transform = .translate(30, 20);
    var g: m.Node = .{
        .id = "g",
        .kind = .group,
        .transform = .translate(100, 100),
        .children = &kids,
    };
    var doc = try testDoc(g);
    defer doc.deinit();
    _ = &g;
    _ = try relayout(testing.allocator, &doc, .{});
    const r = doc.pages[0].children[0];
    try testing.expectEqual(@as(f32, 35), r.size.x);
    try testing.expectEqual(@as(f32, 105), r.transform.e);
    try testing.expectEqual(@as(f32, 0), r.children[0].transform.e);
    try testing.expectEqual(@as(f32, 25), r.children[1].transform.e);
}

test "relayoutFrom grows hugging ancestors" {
    var inner_kids = [_]m.Node{frame("leaf", 10, 10)};
    var inner = frame("inner", 0, 0);
    inner.layout = .{
        .mode = .horizontal,
        .width = .hug,
        .height = .hug,
    };
    inner.children = &inner_kids;
    var outer_kids = [_]m.Node{inner};
    var outer = frame("outer", 0, 0);
    outer.layout = .{
        .mode = .vertical,
        .padding = .{ 5, 5, 5, 5 },
        .width = .hug,
        .height = .hug,
    };
    outer.children = &outer_kids;
    var doc = try testDoc(outer);
    defer doc.deinit();
    _ = try relayout(testing.allocator, &doc, .{});
    try testing.expectEqual(@as(f32, 20), doc.pages[0].children[0].size.x);
    _ = try relayoutFrom(testing.allocator, &doc, "leaf", .{
        .size = .{
            .x = 30,
            .y = 10,
        },
    });
    try testing.expectEqual(@as(f32, 40), doc.pages[0].children[0].size.x);
    try testing.expectEqual(@as(f32, 30), doc.pages[0].children[0].children[0].size.x);
}
