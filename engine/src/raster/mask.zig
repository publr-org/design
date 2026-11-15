//! Coverage masks: how much of each pixel a shape covers, from exact signed areas.

const std = @import("std");
const geom = @import("geom.zig");

const Vec2 = geom.Vec2;
const Polylines = geom.Polylines;

/// Integer pixel bounds, `x0..x1` and `y0..y1` exclusive of the ends.
pub const IRect = struct {
    x0: i32 = 0,
    y0: i32 = 0,
    x1: i32 = 0,
    y1: i32 = 0,

    pub fn width(r: IRect) u32 {
        return @intCast(@max(0, r.x1 - r.x0));
    }

    pub fn height(r: IRect) u32 {
        return @intCast(@max(0, r.y1 - r.y0));
    }

    pub fn isEmpty(r: IRect) bool {
        return r.x1 <= r.x0 or r.y1 <= r.y0;
    }

    pub fn intersect(a: IRect, b: IRect) IRect {
        return .{
            .x0 = @max(a.x0, b.x0),
            .y0 = @max(a.y0, b.y0),
            .x1 = @min(a.x1, b.x1),
            .y1 = @min(a.y1, b.y1),
        };
    }

    pub fn unite(a: IRect, b: IRect) IRect {
        if (a.isEmpty()) return b;
        if (b.isEmpty()) return a;
        return .{
            .x0 = @min(a.x0, b.x0),
            .y0 = @min(a.y0, b.y0),
            .x1 = @max(a.x1, b.x1),
            .y1 = @max(a.y1, b.y1),
        };
    }

    pub fn outset(r: IRect, d: i32) IRect {
        return .{
            .x0 = r.x0 - d,
            .y0 = r.y0 - d,
            .x1 = r.x1 + d,
            .y1 = r.y1 + d,
        };
    }

    /// The pixels a real-valued rectangle touches.
    pub fn around(r: geom.Rect) IRect {
        if (r.isEmpty()) return .{};
        const big: f32 = 1 << 24;
        return .{
            .x0 = @intFromFloat(@floor(std.math.clamp(r.x0, -big, big))),
            .y0 = @intFromFloat(@floor(std.math.clamp(r.y0, -big, big))),
            .x1 = @intFromFloat(@ceil(std.math.clamp(r.x1, -big, big))),
            .y1 = @intFromFloat(@ceil(std.math.clamp(r.y1, -big, big))),
        };
    }
};

pub const Winding = enum {
    nonzero,
    evenodd,
};

/// Coverage 0..1 per pixel over `rect`.
pub const Mask = struct {
    rect: IRect,
    data: []f32,

    pub fn init(gpa: std.mem.Allocator, rect: IRect, value: f32) !Mask {
        const data = try gpa.alloc(f32, rect.width() * rect.height());
        @memset(data, value);
        return .{
            .rect = rect,
            .data = data,
        };
    }

    pub fn deinit(self: *Mask, gpa: std.mem.Allocator) void {
        gpa.free(self.data);
        self.* = undefined;
    }

    /// Coverage at device pixel (x, y); 0 outside.
    pub fn at(self: *const Mask, x: i32, y: i32) f32 {
        if (x < self.rect.x0 or y < self.rect.y0 or x >= self.rect.x1 or y >= self.rect.y1) return 0;
        const w = self.rect.width();
        return self.data[@as(usize, @intCast(y - self.rect.y0)) * w + @as(usize, @intCast(x - self.rect.x0))];
    }

    /// `self *= other` (intersection), pixel by pixel.
    pub fn intersectWith(self: *Mask, other: *const Mask) void {
        const w = self.rect.width();
        var y = self.rect.y0;
        while (y < self.rect.y1) : (y += 1) {
            const row = self.data[@as(usize, @intCast(y - self.rect.y0)) * w ..][0..w];
            for (row, 0..) |*v, i| v.* *= other.at(self.rect.x0 + @as(i32, @intCast(i)), y);
        }
    }

    /// `self *= 1 - other` (subtraction).
    pub fn subtract(self: *Mask, other: *const Mask) void {
        const w = self.rect.width();
        var y = self.rect.y0;
        while (y < self.rect.y1) : (y += 1) {
            const row = self.data[@as(usize, @intCast(y - self.rect.y0)) * w ..][0..w];
            for (row, 0..) |*v, i| v.* *= 1 - other.at(self.rect.x0 + @as(i32, @intCast(i)), y);
        }
    }
};

/// Rasterises closed polylines (open ones are closed implicitly) inside `clip`. The result
/// covers the shape's pixel bounds within `clip`; it may be empty.
pub fn fill(gpa: std.mem.Allocator, polys: *const Polylines, winding: Winding, clip: IRect) !Mask {
    var bounds: geom.Rect = .empty;
    for (polys.points.items) |p| bounds.include(p);
    const rect = IRect.around(bounds).intersect(clip);
    if (rect.isEmpty()) return Mask.init(gpa, .{}, 0);

    const w = rect.width();
    const h = rect.height();
    const stride = w + 2;
    const acc = try gpa.alloc(f32, stride * h);
    defer gpa.free(acc);
    @memset(acc, 0);

    const ox: f32 = @floatFromInt(rect.x0);
    const oy: f32 = @floatFromInt(rect.y0);
    for (polys.contours.items) |c| {
        const pts = polys.contour(c);
        var i: usize = 0;
        while (i < pts.len) : (i += 1) {
            const a = pts[i];
            const b = if (i + 1 < pts.len) pts[i + 1] else pts[0];
            accumulateLine(acc, stride, w, h, .{
                .x = a.x - ox,
                .y = a.y - oy,
            }, .{
                .x = b.x - ox,
                .y = b.y - oy,
            });
        }
    }

    var mask = try Mask.init(gpa, rect, 0);
    var y: usize = 0;
    while (y < h) : (y += 1) {
        var sum: f32 = 0;
        const src = acc[y * stride ..][0..stride];
        const dst = mask.data[y * w ..][0..w];
        for (dst, 0..) |*d, x| {
            sum += src[x];
            d.* = switch (winding) {
                .nonzero => @min(1, @abs(sum)),
                .evenodd => @abs(sum - 2 * @round(sum / 2)),
            };
        }
    }
    return mask;
}

/// Sample positions inside a pixel, each `[x, y]` in 0..1.
pub const Pattern = []const [2]f32;

/// A regular 4 x 4 grid.
pub const grid16: [16][2]f32 = blk: {
    var p: [16][2]f32 = undefined;
    for (0..4) |j| for (0..4) |i| {
        p[j * 4 + i] = .{ (@as(f32, @floatFromInt(i)) + 0.5) / 4, (@as(f32, @floatFromInt(j)) + 0.5) / 4 };
    };
    break :blk p;
};

/// The standard 16x multisample positions GPUs use (offsets in 1/16 pixel from the centre).
pub const standard16: [16][2]f32 = blk: {
    const o = [16][2]f32{
        .{ 1, 1 },   .{ -1, -3 }, .{ -3, 2 },  .{ 4, -1 },
        .{ -5, -2 }, .{ 2, 5 },   .{ 5, 3 },   .{ 3, -5 },
        .{ -2, 6 },  .{ 0, -7 },  .{ -4, -6 }, .{ -6, 4 },
        .{ -8, 0 },  .{ 7, -4 },  .{ 6, 7 },   .{ -7, -8 },
    };
    var p: [16][2]f32 = undefined;
    for (o, 0..) |v, i| p[i] = .{ 0.5 + v[0] / 16, 0.5 + v[1] / 16 };
    break :blk p;
};

/// Figma's anti-aliasing: 4x multisampling at twice the resolution, averaged down (16
/// samples, 8 distinct rows and columns). Found by matching its renders.
pub const figma16: [16][2]f32 = blk: {
    const base = [4][2]f32{ .{ -2, -6 }, .{ 6, -2 }, .{ -6, 2 }, .{ 2, 6 } };
    var p: [16][2]f32 = undefined;
    var i: usize = 0;
    for (0..2) |sy| for (0..2) |sx| for (base) |v| {
        p[i] = .{
            (@as(f32, @floatFromInt(sx)) + 0.5 + v[0] / 16) / 2,
            (@as(f32, @floatFromInt(sy)) + 0.5 + v[1] / 16) / 2,
        };
        i += 1;
    };
    break :blk p;
};

/// Rasterises like `fill`, but coverage is the share of `pattern`'s sample points inside
/// the shape (how multisampled renderers anti-alias).
pub fn fillSampled(gpa: std.mem.Allocator, polys: *const Polylines, winding: Winding, clip: IRect, pattern: Pattern) !Mask {
    var bounds: geom.Rect = .empty;
    for (polys.points.items) |p| bounds.include(p);
    const rect = IRect.around(bounds).intersect(clip);
    if (rect.isEmpty()) return Mask.init(gpa, .{}, 0);
    var mask = try Mask.init(gpa, rect, 0);
    errdefer mask.deinit(gpa);
    const w = rect.width();
    const h = rect.height();
    const inv: f32 = 1 / @as(f32, @floatFromInt(pattern.len));

    const Crossing = struct {
        x: f32,
        dir: i32,

        fn lt(_: void, a: @This(), b: @This()) bool {
            return a.x < b.x;
        }
    };
    var xs: std.ArrayList(Crossing) = .empty;
    defer xs.deinit(gpa);

    // Every non-horizontal edge once, sorted by where it starts; each row tests only the
    // edges spanning it (an active list), not the whole path: a paragraph's glyphs are
    // one path of thousands of edges. Crossings are the same numbers, in the same order
    // once sorted, as testing every edge.
    const Edge = struct {
        a: Vec2,
        b: Vec2,
        lo: f32,
        hi: f32,
        /// Position in the path, so crossings keep the path's order.
        order: u32,

        fn byLo(_: void, x: @This(), y: @This()) bool {
            return x.lo < y.lo;
        }
    };
    var edges: std.ArrayList(Edge) = .empty;
    defer edges.deinit(gpa);
    var pmin: f32 = std.math.inf(f32);
    var pmax: f32 = -std.math.inf(f32);
    for (pattern) |sp| {
        pmin = @min(pmin, sp[1]);
        pmax = @max(pmax, sp[1]);
    }
    const top = @as(f32, @floatFromInt(rect.y0)) + pmin;
    const bottom = @as(f32, @floatFromInt(rect.y1 - 1)) + pmax;
    var order: u32 = 0;
    for (polys.contours.items) |c| {
        const pts = polys.contour(c);
        for (pts, 0..) |a, i| {
            const b = if (i + 1 < pts.len) pts[i + 1] else pts[0];
            if (a.y == b.y) continue;
            const lo = @min(a.y, b.y);
            const hi = @max(a.y, b.y);
            order += 1;
            if (hi <= top or lo > bottom) continue;
            try edges.append(gpa, .{
                .a = a,
                .b = b,
                .lo = lo,
                .hi = hi,
                .order = order,
            });
        }
    }
    std.mem.sort(Edge, edges.items, {}, Edge.byLo);
    var active: std.ArrayList(Edge) = .empty;
    defer active.deinit(gpa);
    var next: usize = 0;
    const counts = try gpa.alloc(i32, w + 1);
    defer gpa.free(counts);

    var y: u32 = 0;
    while (y < h) : (y += 1) {
        const row = mask.data[y * w ..][0..w];
        const fy = @as(f32, @floatFromInt(rect.y0 + @as(i32, @intCast(y))));
        // Drop edges that end above this row's first sample, take those starting by its last.
        var keep: usize = 0;
        for (active.items) |e| {
            if (e.hi > fy + pmin) {
                active.items[keep] = e;
                keep += 1;
            }
        }
        active.shrinkRetainingCapacity(keep);
        var added = false;
        while (next < edges.items.len and edges.items[next].lo <= fy + pmax) : (next += 1) {
            if (edges.items[next].hi > fy + pmin) {
                try active.append(gpa, edges.items[next]);
                added = true;
            }
        }
        if (added) std.mem.sort(Edge, active.items, {}, struct {
            fn lt(_: void, x: Edge, z: Edge) bool {
                return x.order < z.order;
            }
        }.lt);
        // Each sample row adds its inside spans to a difference array; one running sum
        // then gives every pixel its count of inside samples (count / n is exactly the
        // sum of n-ths: they are powers of two).
        @memset(counts, 0);
        var any = false;
        for (pattern) |sp| {
            const sy = fy + sp[1];
            xs.clearRetainingCapacity();
            for (active.items) |e| {
                // Half-open rule: an edge covers y in [min, max).
                if (sy < e.lo or sy >= e.hi) continue;
                const t = (sy - e.a.y) / (e.b.y - e.a.y);
                try xs.append(gpa, .{
                    .x = e.a.x + (e.b.x - e.a.x) * t,
                    .dir = if (e.b.y > e.a.y) 1 else -1,
                });
            }
            if (xs.items.len == 0) continue;
            any = true;
            std.mem.sort(Crossing, xs.items, {}, Crossing.lt);
            // A pixel is past a crossing when its sample lies at or right of it.
            var wind: i32 = 0;
            var from: usize = 0;
            for (xs.items) |c| {
                const at = firstAtOrPast(rect.x0, w, sp[0], c.x);
                if (at > from and isInside(wind, winding)) {
                    counts[from] += 1;
                    counts[at] -= 1;
                }
                wind += c.dir;
                from = @max(from, at);
            }
            if (from < w and isInside(wind, winding)) {
                counts[from] += 1;
                counts[w] -= 1;
            }
        }
        if (!any) continue;
        var run: i32 = 0;
        for (row, counts[0..w]) |*v, d| {
            run += d;
            v.* = @as(f32, @floatFromInt(run)) * inv;
        }
    }
    return mask;
}

fn isInside(wind: i32, winding: Winding) bool {
    return switch (winding) {
        .nonzero => wind != 0,
        .evenodd => @mod(wind, 2) != 0,
    };
}

/// The first pixel of a row (`x0`, `w` wide) whose sample at offset `sx` lies at or past
/// `x`, computed as the per-pixel test computes it; `w` when none does.
fn firstAtOrPast(x0: i32, w: u32, sx: f32, x: f32) usize {
    const sample = struct {
        fn at(o: i32, i: i64, s: f32) f32 {
            return @as(f32, @floatFromInt(o + @as(i32, @intCast(i)))) + s;
        }
    }.at;
    if (!(x > sample(x0, 0, sx))) return 0;
    const wi: i64 = w;
    const guess = @ceil(x - sx) - @as(f32, @floatFromInt(x0));
    var i: i64 = if (guess != guess) wi else @intFromFloat(std.math.clamp(guess, 0, @as(f32, @floatFromInt(w))));
    while (i > 0 and sample(x0, i - 1, sx) >= x) i -= 1;
    while (i < wi and sample(x0, i, sx) < x) i += 1;
    return @intCast(i);
}

/// Adds one edge's signed area to the accumulation buffer.
fn accumulateLine(acc: []f32, stride: usize, w: u32, h: u32, p0: Vec2, p1: Vec2) void {
    if (p0.y == p1.y) return;
    const fw: f32 = @floatFromInt(w);
    const fh: f32 = @floatFromInt(h);
    var dir: f32 = 1;
    var a = p0;
    var b = p1;
    if (a.y > b.y) {
        dir = -1;
        std.mem.swap(Vec2, &a, &b);
    }
    if (b.y <= 0 or a.y >= fh) return;
    const dxdy = (b.x - a.x) / (b.y - a.y);
    var x = a.x;
    var y0 = a.y;
    if (y0 < 0) {
        x -= y0 * dxdy;
        y0 = 0;
    }
    const y1 = @min(b.y, fh);
    var yi: usize = @intFromFloat(@floor(y0));
    const yend: usize = @intFromFloat(@ceil(y1));
    while (yi < yend) : (yi += 1) {
        const fy: f32 = @floatFromInt(yi);
        const dy = @min(fy + 1, y1) - @max(fy, y0);
        const xnext = x + dxdy * dy;
        const d = dy * dir;
        // Edges left of the mask count at its left edge; right of it, past its end.
        const xa = std.math.clamp(@min(x, xnext), 0, fw);
        const xb = std.math.clamp(@max(x, xnext), 0, fw);
        const row = acc[yi * stride ..][0..stride];
        const x0f = @floor(xa);
        const x0i: usize = @intFromFloat(x0f);
        const x1c = @ceil(xb);
        const x1i: usize = @intFromFloat(x1c);
        if (x1i <= x0i + 1) {
            const xmf = 0.5 * (xa + xb) - x0f;
            row[x0i] += d - d * xmf;
            row[x0i + 1] += d * xmf;
        } else {
            const s = 1 / (xb - xa);
            const x0frac = xa - x0f;
            const a0 = 0.5 * s * (1 - x0frac) * (1 - x0frac);
            const x1frac = xb - x1c + 1;
            const am = 0.5 * s * x1frac * x1frac;
            row[x0i] += d * a0;
            if (x1i == x0i + 2) {
                row[x0i + 1] += d * (1 - a0 - am);
            } else {
                const a1 = s * (1.5 - x0frac);
                row[x0i + 1] += d * (a1 - a0);
                var xi = x0i + 2;
                while (xi < x1i - 1) : (xi += 1) row[xi] += d * s;
                const a2 = a1 + @as(f32, @floatFromInt(x1i - x0i - 3)) * s;
                row[x1i - 1] += d * (1 - a2 - am);
            }
            row[x1i] += d * am;
        }
        x = xnext;
    }
}

pub const Cap = enum {
    butt,
    round,
    square,
};

pub const Join = enum {
    miter,
    round,
    bevel,
};

pub const StrokeStyle = struct {
    width: f32,
    cap: Cap = .butt,
    join: Join = .miter,
    miter_limit: f32 = 4,
};

/// Outlines the polylines as stroke polygons, all wound the same way so they union under
/// the nonzero rule.
pub fn strokeOutline(gpa: std.mem.Allocator, polys: *const Polylines, style: StrokeStyle, out: *Polylines) !void {
    const hw = style.width / 2;
    if (hw <= 0) return;
    for (polys.contours.items) |c| {
        const raw = polys.contour(c);
        // Drop repeated points.
        var pts: std.ArrayList(Vec2) = .empty;
        defer pts.deinit(gpa);
        for (raw) |p| {
            if (pts.items.len == 0 or pts.items[pts.items.len - 1].sub(p).len() > 1e-5) try pts.append(gpa, p);
        }
        if (c.closed and pts.items.len > 2 and pts.items[0].sub(pts.items[pts.items.len - 1]).len() <= 1e-5) _ = pts.pop();
        const n = pts.items.len;
        if (n < 2) {
            if (n == 1 and style.cap == .round) try addCircle(gpa, out, pts.items[0], hw);
            continue;
        }
        const seg_count = if (c.closed) n else n - 1;
        var i: usize = 0;
        while (i < seg_count) : (i += 1) {
            const a = pts.items[i];
            const b = pts.items[(i + 1) % n];
            const nrm = normal(a, b).scale(hw);
            try addPolygon(gpa, out, &.{ a.add(nrm), b.add(nrm), b.sub(nrm), a.sub(nrm) });
        }
        // Joins at interior vertices (all vertices when closed).
        var j: usize = if (c.closed) 0 else 1;
        const jend = if (c.closed) n else n - 1;
        while (j < jend) : (j += 1) {
            const prev = pts.items[(j + n - 1) % n];
            const p = pts.items[j];
            const next = pts.items[(j + 1) % n];
            try addJoin(gpa, out, prev, p, next, hw, style);
        }
        if (!c.closed) {
            try addCap(gpa, out, pts.items[1], pts.items[0], hw, style.cap);
            try addCap(gpa, out, pts.items[n - 2], pts.items[n - 1], hw, style.cap);
        }
    }
}

fn normal(a: Vec2, b: Vec2) Vec2 {
    const d = b.sub(a);
    const l = d.len();
    if (l == 0) return .{};
    return .{
        .x = -d.y / l,
        .y = d.x / l,
    };
}

fn addPolygon(gpa: std.mem.Allocator, out: *Polylines, pts: []const Vec2) !void {
    var area: f32 = 0;
    for (pts, 0..) |p, i| {
        const q = pts[(i + 1) % pts.len];
        area += p.x * q.y - q.x * p.y;
    }
    if (@abs(area) < 1e-9) return;
    const start: u32 = @intCast(out.points.items.len);
    if (area > 0) {
        try out.points.appendSlice(gpa, pts);
    } else {
        var k = pts.len;
        while (k > 0) {
            k -= 1;
            try out.points.append(gpa, pts[k]);
        }
    }
    try out.contours.append(gpa, .{
        .start = start,
        .end = @intCast(out.points.items.len),
        .closed = true,
    });
}

fn addCircle(gpa: std.mem.Allocator, out: *Polylines, c: Vec2, r: f32) !void {
    var pts: [48]Vec2 = undefined;
    const n: usize = if (r < 2) 16 else 48;
    for (pts[0..n], 0..) |*p, i| {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n)) * std.math.tau;
        p.* = .{
            .x = c.x + r * @cos(t),
            .y = c.y + r * @sin(t),
        };
    }
    try addPolygon(gpa, out, pts[0..n]);
}

fn addJoin(gpa: std.mem.Allocator, out: *Polylines, prev: Vec2, p: Vec2, next: Vec2, hw: f32, style: StrokeStyle) !void {
    const n0 = normal(prev, p);
    const n1 = normal(p, next);
    const cross = n0.x * n1.y - n0.y * n1.x;
    if (@abs(cross) < 1e-6 and n0.x * n1.x + n0.y * n1.y > 0) return;
    // The outer side is where the two offset edges open a gap.
    const s: f32 = if (cross > 0) -1 else 1;
    const a = p.add(n0.scale(hw * s));
    const b = p.add(n1.scale(hw * s));
    switch (style.join) {
        .round => try addCircle(gpa, out, p, hw),
        .bevel => try addPolygon(gpa, out, &.{ p, a, b }),
        .miter => {
            const bis = n0.add(n1);
            const bl = bis.len();
            const cos_half = bl / 2;
            if (bl < 1e-6 or 1 / cos_half > style.miter_limit) {
                try addPolygon(gpa, out, &.{ p, a, b });
            } else {
                const tip = p.add(bis.scale(s * hw / (cos_half * bl)));
                try addPolygon(gpa, out, &.{ p, a, tip, b });
            }
        },
    }
}

fn addCap(gpa: std.mem.Allocator, out: *Polylines, from: Vec2, end: Vec2, hw: f32, cap: Cap) !void {
    switch (cap) {
        .butt => {},
        .round => try addCircle(gpa, out, end, hw),
        .square => {
            const d = end.sub(from);
            const l = d.len();
            if (l == 0) return;
            const t = d.scale(hw / l);
            const nrm = Vec2{
                .x = -t.y,
                .y = t.x,
            };
            try addPolygon(gpa, out, &.{ end.add(nrm), end.add(nrm).add(t), end.sub(nrm).add(t), end.sub(nrm) });
        },
    }
}

test "pixel-aligned square covers exactly" {
    const gpa = std.testing.allocator;
    var p: geom.Path = .{};
    defer p.deinit(gpa);
    try p.addRoundRect(gpa, 4, 4, .{ 0, 0, 0, 0 });
    p.transform(geom.Affine.translate(1, 1));
    var polys: Polylines = .{};
    defer polys.deinit(gpa);
    try p.flatten(gpa, 0.1, &polys);
    var m = try fill(gpa, &polys, .nonzero, .{
        .x0 = 0,
        .y0 = 0,
        .x1 = 8,
        .y1 = 8,
    });
    defer m.deinit(gpa);
    try std.testing.expectEqual(@as(f32, 1), m.at(1, 1));
    try std.testing.expectEqual(@as(f32, 1), m.at(4, 4));
    try std.testing.expectEqual(@as(f32, 0), m.at(5, 5));
    try std.testing.expectEqual(@as(f32, 0), m.at(0, 0));
}

test "half-pixel edge covers half" {
    const gpa = std.testing.allocator;
    var p: geom.Path = .{};
    defer p.deinit(gpa);
    try p.addRoundRect(gpa, 2.5, 2, .{ 0, 0, 0, 0 });
    var polys: Polylines = .{};
    defer polys.deinit(gpa);
    try p.flatten(gpa, 0.1, &polys);
    var m = try fill(gpa, &polys, .nonzero, .{
        .x0 = 0,
        .y0 = 0,
        .x1 = 4,
        .y1 = 4,
    });
    defer m.deinit(gpa);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), m.at(2, 0), 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 1), m.at(1, 1), 1e-5);
}

test "evenodd hole" {
    const gpa = std.testing.allocator;
    var p: geom.Path = .{};
    defer p.deinit(gpa);
    try p.addRoundRect(gpa, 6, 6, .{ 0, 0, 0, 0 });
    var inner: geom.Path = .{};
    defer inner.deinit(gpa);
    try inner.addRoundRect(gpa, 2, 2, .{ 0, 0, 0, 0 });
    inner.transform(geom.Affine.translate(2, 2));
    var polys: Polylines = .{};
    defer polys.deinit(gpa);
    try p.flatten(gpa, 0.1, &polys);
    try inner.flatten(gpa, 0.1, &polys);
    var m = try fill(gpa, &polys, .evenodd, .{
        .x0 = 0,
        .y0 = 0,
        .x1 = 6,
        .y1 = 6,
    });
    defer m.deinit(gpa);
    try std.testing.expectEqual(@as(f32, 0), m.at(2, 2));
    try std.testing.expectEqual(@as(f32, 1), m.at(0, 0));
}

test "stroke of a square" {
    const gpa = std.testing.allocator;
    var p: geom.Path = .{};
    defer p.deinit(gpa);
    try p.addRoundRect(gpa, 10, 10, .{ 0, 0, 0, 0 });
    p.transform(geom.Affine.translate(2, 2));
    var polys: Polylines = .{};
    defer polys.deinit(gpa);
    try p.flatten(gpa, 0.1, &polys);
    var outline: Polylines = .{};
    defer outline.deinit(gpa);
    try strokeOutline(gpa, &polys, .{
        .width = 2,
    }, &outline);
    var m = try fill(gpa, &outline, .nonzero, .{
        .x0 = 0,
        .y0 = 0,
        .x1 = 16,
        .y1 = 16,
    });
    defer m.deinit(gpa);
    try std.testing.expectApproxEqAbs(@as(f32, 1), m.at(1, 1), 1e-4); // miter corner
    try std.testing.expectApproxEqAbs(@as(f32, 1), m.at(6, 2), 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 0), m.at(6, 6), 1e-4);
}

test "sampled fill with an active edge list matches testing every edge" {
    const gpa = std.testing.allocator;
    var prng: std.Random.DefaultPrng = .init(7);
    const rnd = prng.random();
    for (0..20) |round| {
        // Many small random polygons (like glyphs) plus a few large ones.
        var polys: Polylines = .{};
        defer polys.deinit(gpa);
        for (0..30) |k| {
            const cx = rnd.float(f32) * 60 - 5;
            const cy = rnd.float(f32) * 60 - 5;
            const r: f32 = if (k % 10 == 0) 40 else 4;
            const start: u32 = @intCast(polys.points.items.len);
            const n = 3 + rnd.uintLessThan(u32, 6);
            for (0..n) |_| try polys.points.append(gpa, .{
                .x = cx + (rnd.float(f32) - 0.5) * r,
                .y = cy + (rnd.float(f32) - 0.5) * r,
            });
            try polys.contours.append(gpa, .{
                .start = start,
                .end = @intCast(polys.points.items.len),
                .closed = true,
            });
        }
        const winding: Winding = if (round % 2 == 0) .nonzero else .evenodd;
        const clip: IRect = .{
            .x0 = 3,
            .y0 = 2,
            .x1 = 47,
            .y1 = 51,
        };
        var got = try fillSampled(gpa, &polys, winding, clip, &figma16);
        defer got.deinit(gpa);

        // The reference: every edge tested for every sample row.
        var want = try Mask.init(gpa, got.rect, 0);
        defer want.deinit(gpa);
        const w = got.rect.width();
        var y: u32 = 0;
        while (y < got.rect.height()) : (y += 1) {
            for (figma16) |sp| {
                const sy = @as(f32, @floatFromInt(got.rect.y0 + @as(i32, @intCast(y)))) + sp[1];
                var xs: [512]struct {
                    x: f32,
                    dir: i32,
                } = undefined;
                var n: usize = 0;
                for (polys.contours.items) |c| {
                    const pts = polys.contour(c);
                    for (pts, 0..) |a, i| {
                        const b = if (i + 1 < pts.len) pts[i + 1] else pts[0];
                        if (a.y == b.y or sy < @min(a.y, b.y) or sy >= @max(a.y, b.y)) continue;
                        const t = (sy - a.y) / (b.y - a.y);
                        xs[n] = .{
                            .x = a.x + (b.x - a.x) * t,
                            .dir = if (b.y > a.y) 1 else -1,
                        };
                        n += 1;
                    }
                }
                var xi: u32 = 0;
                while (xi < w) : (xi += 1) {
                    const sx = @as(f32, @floatFromInt(got.rect.x0 + @as(i32, @intCast(xi)))) + sp[0];
                    var wind: i32 = 0;
                    for (xs[0..n]) |c| {
                        if (c.x <= sx) wind += c.dir;
                    }
                    const inside = switch (winding) {
                        .nonzero => wind != 0,
                        .evenodd => @mod(wind, 2) != 0,
                    };
                    if (inside) want.data[y * w + xi] += 1.0 / 16.0;
                }
            }
        }
        try std.testing.expectEqualSlices(f32, want.data, got.data);
    }
}
