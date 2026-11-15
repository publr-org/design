//! Points, transforms and paths.

const std = @import("std");

pub const Vec2 = struct {
    x: f32 = 0,
    y: f32 = 0,

    pub fn add(a: Vec2, b: Vec2) Vec2 {
        return .{
            .x = a.x + b.x,
            .y = a.y + b.y,
        };
    }

    pub fn sub(a: Vec2, b: Vec2) Vec2 {
        return .{
            .x = a.x - b.x,
            .y = a.y - b.y,
        };
    }

    pub fn scale(a: Vec2, s: f32) Vec2 {
        return .{
            .x = a.x * s,
            .y = a.y * s,
        };
    }

    pub fn len(a: Vec2) f32 {
        return @sqrt(a.x * a.x + a.y * a.y);
    }

    pub fn lerp(a: Vec2, b: Vec2, t: f32) Vec2 {
        return .{
            .x = a.x + (b.x - a.x) * t,
            .y = a.y + (b.y - a.y) * t,
        };
    }
};

/// `x' = a*x + c*y + e`, `y' = b*x + d*y + f`.
pub const Affine = struct {
    a: f32 = 1,
    b: f32 = 0,
    c: f32 = 0,
    d: f32 = 1,
    e: f32 = 0,
    f: f32 = 0,

    pub const identity: Affine = .{};

    pub fn translate(x: f32, y: f32) Affine {
        return .{
            .e = x,
            .f = y,
        };
    }

    pub fn scaling(sx: f32, sy: f32) Affine {
        return .{
            .a = sx,
            .d = sy,
        };
    }

    /// `self` after `inner`: apply `inner` first.
    pub fn mul(self: Affine, inner: Affine) Affine {
        return .{
            .a = self.a * inner.a + self.c * inner.b,
            .b = self.b * inner.a + self.d * inner.b,
            .c = self.a * inner.c + self.c * inner.d,
            .d = self.b * inner.c + self.d * inner.d,
            .e = self.a * inner.e + self.c * inner.f + self.e,
            .f = self.b * inner.e + self.d * inner.f + self.f,
        };
    }

    pub fn apply(self: Affine, p: Vec2) Vec2 {
        return .{
            .x = self.a * p.x + self.c * p.y + self.e,
            .y = self.b * p.x + self.d * p.y + self.f,
        };
    }

    pub fn applyVector(self: Affine, p: Vec2) Vec2 {
        return .{
            .x = self.a * p.x + self.c * p.y,
            .y = self.b * p.x + self.d * p.y,
        };
    }

    pub fn det(self: Affine) f32 {
        return self.a * self.d - self.b * self.c;
    }

    pub fn invert(self: Affine) ?Affine {
        const dt = self.det();
        if (@abs(dt) < 1e-12) return null;
        const id = 1 / dt;
        return .{
            .a = self.d * id,
            .b = -self.b * id,
            .c = -self.c * id,
            .d = self.a * id,
            .e = (self.c * self.f - self.d * self.e) * id,
            .f = (self.b * self.e - self.a * self.f) * id,
        };
    }

    /// The largest factor this transform scales a length by.
    pub fn maxScale(self: Affine) f32 {
        const sx = @sqrt(self.a * self.a + self.b * self.b);
        const sy = @sqrt(self.c * self.c + self.d * self.d);
        return @max(sx, sy);
    }
};

pub const Rect = struct {
    x0: f32 = 0,
    y0: f32 = 0,
    x1: f32 = 0,
    y1: f32 = 0,

    pub const empty: Rect = .{
        .x0 = std.math.inf(f32),
        .y0 = std.math.inf(f32),
        .x1 = -std.math.inf(f32),
        .y1 = -std.math.inf(f32),
    };

    pub fn isEmpty(r: Rect) bool {
        return !(r.x1 > r.x0 and r.y1 > r.y0);
    }

    pub fn include(r: *Rect, p: Vec2) void {
        r.x0 = @min(r.x0, p.x);
        r.y0 = @min(r.y0, p.y);
        r.x1 = @max(r.x1, p.x);
        r.y1 = @max(r.y1, p.y);
    }

    pub fn unite(a: Rect, b: Rect) Rect {
        return .{
            .x0 = @min(a.x0, b.x0),
            .y0 = @min(a.y0, b.y0),
            .x1 = @max(a.x1, b.x1),
            .y1 = @max(a.y1, b.y1),
        };
    }

    pub fn intersect(a: Rect, b: Rect) Rect {
        return .{
            .x0 = @max(a.x0, b.x0),
            .y0 = @max(a.y0, b.y0),
            .x1 = @min(a.x1, b.x1),
            .y1 = @min(a.y1, b.y1),
        };
    }

    pub fn outset(r: Rect, d: f32) Rect {
        return .{
            .x0 = r.x0 - d,
            .y0 = r.y0 - d,
            .x1 = r.x1 + d,
            .y1 = r.y1 + d,
        };
    }

    pub fn transformed(r: Rect, m: Affine) Rect {
        var out: Rect = .empty;
        out.include(m.apply(.{
            .x = r.x0,
            .y = r.y0,
        }));
        out.include(m.apply(.{
            .x = r.x1,
            .y = r.y0,
        }));
        out.include(m.apply(.{
            .x = r.x0,
            .y = r.y1,
        }));
        out.include(m.apply(.{
            .x = r.x1,
            .y = r.y1,
        }));
        return out;
    }
};

pub const Verb = enum {
    move,
    line,
    cubic,
    close,
};

/// A path: verbs and their points (move 1, line 1, cubic 3, close 0).
pub const Path = struct {
    verbs: std.ArrayList(Verb) = .empty,
    points: std.ArrayList(Vec2) = .empty,

    pub fn deinit(self: *Path, gpa: std.mem.Allocator) void {
        self.verbs.deinit(gpa);
        self.points.deinit(gpa);
    }

    pub fn moveTo(self: *Path, gpa: std.mem.Allocator, p: Vec2) !void {
        try self.verbs.append(gpa, .move);
        try self.points.append(gpa, p);
    }

    pub fn lineTo(self: *Path, gpa: std.mem.Allocator, p: Vec2) !void {
        try self.verbs.append(gpa, .line);
        try self.points.append(gpa, p);
    }

    pub fn cubicTo(self: *Path, gpa: std.mem.Allocator, c1: Vec2, c2: Vec2, p: Vec2) !void {
        try self.verbs.append(gpa, .cubic);
        try self.points.appendSlice(gpa, &.{ c1, c2, p });
    }

    pub fn close(self: *Path, gpa: std.mem.Allocator) !void {
        try self.verbs.append(gpa, .close);
    }

    pub fn transform(self: *Path, m: Affine) void {
        for (self.points.items) |*p| p.* = m.apply(p.*);
    }

    /// Control-point bounds (contain the curve).
    pub fn bounds(self: *const Path) Rect {
        var r: Rect = .empty;
        for (self.points.items) |p| r.include(p);
        return r;
    }

    /// A rectangle with per-corner radii (tl, tr, br, bl), clamped the way design tools do:
    /// radii shrink together until adjacent ones fit their side.
    pub fn addRoundRect(self: *Path, gpa: std.mem.Allocator, w: f32, h: f32, radii: [4]f32) !void {
        var r = radii;
        for (&r) |*v| v.* = @max(0, v.*);
        var f: f32 = 1;
        const sides = [4]struct {
            a: f32,
            b: f32,
            l: f32,
        }{
            .{
                .a = r[0],
                .b = r[1],
                .l = w,
            },
            .{
                .a = r[1],
                .b = r[2],
                .l = h,
            },
            .{
                .a = r[2],
                .b = r[3],
                .l = w,
            },
            .{
                .a = r[3],
                .b = r[0],
                .l = h,
            },
        };
        for (sides) |s| {
            if (s.a + s.b > s.l and s.a + s.b > 0) f = @min(f, s.l / (s.a + s.b));
        }
        for (&r) |*v| v.* *= f;
        if (r[0] == 0 and r[1] == 0 and r[2] == 0 and r[3] == 0) {
            try self.moveTo(gpa, .{});
            try self.lineTo(gpa, .{
                .x = w,
            });
            try self.lineTo(gpa, .{
                .x = w,
                .y = h,
            });
            try self.lineTo(gpa, .{
                .y = h,
            });
            try self.close(gpa);
            return;
        }
        const k: f32 = 0.5522847498;
        try self.moveTo(gpa, .{
            .x = r[0],
        });
        try self.lineTo(gpa, .{
            .x = w - r[1],
        });
        if (r[1] > 0) try self.cubicTo(gpa, .{
            .x = w - r[1] + r[1] * k,
        }, .{
            .x = w,
            .y = r[1] - r[1] * k,
        }, .{
            .x = w,
            .y = r[1],
        });
        try self.lineTo(gpa, .{
            .x = w,
            .y = h - r[2],
        });
        if (r[2] > 0) try self.cubicTo(gpa, .{
            .x = w,
            .y = h - r[2] + r[2] * k,
        }, .{
            .x = w - r[2] + r[2] * k,
            .y = h,
        }, .{
            .x = w - r[2],
            .y = h,
        });
        try self.lineTo(gpa, .{
            .x = r[3],
            .y = h,
        });
        if (r[3] > 0) try self.cubicTo(gpa, .{
            .x = r[3] - r[3] * k,
            .y = h,
        }, .{
            .y = h - r[3] + r[3] * k,
        }, .{
            .y = h - r[3],
        });
        try self.lineTo(gpa, .{
            .y = r[0],
        });
        if (r[0] > 0) try self.cubicTo(gpa, .{
            .y = r[0] - r[0] * k,
        }, .{
            .x = r[0] - r[0] * k,
        }, .{
            .x = r[0],
        });
        try self.close(gpa);
    }

    /// A full ellipse filling `w` x `h`.
    pub fn addEllipse(self: *Path, gpa: std.mem.Allocator, w: f32, h: f32) !void {
        const rx = w / 2;
        const ry = h / 2;
        const k: f32 = 0.5522847498;
        try self.moveTo(gpa, .{
            .x = w,
            .y = ry,
        });
        try self.cubicTo(gpa, .{
            .x = w,
            .y = ry + ry * k,
        }, .{
            .x = rx + rx * k,
            .y = h,
        }, .{
            .x = rx,
            .y = h,
        });
        try self.cubicTo(gpa, .{
            .x = rx - rx * k,
            .y = h,
        }, .{
            .y = ry + ry * k,
        }, .{
            .y = ry,
        });
        try self.cubicTo(gpa, .{
            .y = ry - ry * k,
        }, .{
            .x = rx - rx * k,
        }, .{
            .x = rx,
        });
        try self.cubicTo(gpa, .{
            .x = rx + rx * k,
        }, .{
            .x = w,
            .y = ry - ry * k,
        }, .{
            .x = w,
            .y = ry,
        });
        try self.close(gpa);
    }

    /// Flattens into closed or open polylines, appending to `out`. `tolerance` is the
    /// largest distance a line may stray from the curve.
    pub fn flatten(self: *const Path, gpa: std.mem.Allocator, tolerance: f32, out: *Polylines) !void {
        var pi: usize = 0;
        var cur: Vec2 = .{};
        var start: Vec2 = .{};
        var open = false;
        for (self.verbs.items) |v| switch (v) {
            .move => {
                if (open) try out.end(gpa, false);
                cur = self.points.items[pi];
                start = cur;
                pi += 1;
                try out.begin(gpa, cur);
                open = true;
            },
            .line => {
                cur = self.points.items[pi];
                pi += 1;
                try out.push(gpa, cur);
            },
            .cubic => {
                const c1 = self.points.items[pi];
                const c2 = self.points.items[pi + 1];
                const p = self.points.items[pi + 2];
                pi += 3;
                // Segments from the control polygon's deviation (Wang's formula).
                const dd1 = cur.sub(c1.scale(2)).add(c2);
                const dd2 = c1.sub(c2.scale(2)).add(p);
                const m = @max(dd1.len(), dd2.len());
                const n_f = @ceil(@sqrt(0.75 * m / @max(tolerance, 1e-3)));
                const n: u32 = @intFromFloat(@min(@max(n_f, 1), 512));
                var i: u32 = 1;
                while (i <= n) : (i += 1) {
                    const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n));
                    try out.push(gpa, cubicAt(cur, c1, c2, p, t));
                }
                cur = p;
            },
            .close => {
                if (open) try out.end(gpa, true);
                open = false;
                cur = start;
            },
        };
        if (open) try out.end(gpa, false);
    }
};

/// Appends SVG path data (absolute M, L, H, V, C, Q, Z) to `out`; stops at anything else.
pub fn parseSvgPath(gpa: std.mem.Allocator, d: []const u8, out: *Path) !void {
    var i: usize = 0;
    var cmd: u8 = 0;
    var cur: Vec2 = .{};
    var start: Vec2 = .{};
    while (true) {
        while (i < d.len and (d[i] == ' ' or d[i] == ',' or d[i] == '\n')) i += 1;
        if (i >= d.len) break;
        if (std.ascii.isAlphabetic(d[i])) {
            cmd = d[i];
            i += 1;
            if (cmd == 'Z' or cmd == 'z') {
                try out.close(gpa);
                cur = start;
                continue;
            }
        }
        switch (cmd) {
            'M' => {
                cur = .{
                    .x = try num(d, &i),
                    .y = try num(d, &i),
                };
                start = cur;
                try out.moveTo(gpa, cur);
                cmd = 'L';
            },
            'L' => {
                cur = .{
                    .x = try num(d, &i),
                    .y = try num(d, &i),
                };
                try out.lineTo(gpa, cur);
            },
            'H' => {
                cur.x = try num(d, &i);
                try out.lineTo(gpa, cur);
            },
            'V' => {
                cur.y = try num(d, &i);
                try out.lineTo(gpa, cur);
            },
            'C' => {
                const c1: Vec2 = .{
                    .x = try num(d, &i),
                    .y = try num(d, &i),
                };
                const c2: Vec2 = .{
                    .x = try num(d, &i),
                    .y = try num(d, &i),
                };
                cur = .{
                    .x = try num(d, &i),
                    .y = try num(d, &i),
                };
                try out.cubicTo(gpa, c1, c2, cur);
            },
            'Q' => {
                const q: Vec2 = .{
                    .x = try num(d, &i),
                    .y = try num(d, &i),
                };
                const p: Vec2 = .{
                    .x = try num(d, &i),
                    .y = try num(d, &i),
                };
                // A quadratic as an exact cubic.
                try out.cubicTo(gpa, cur.lerp(q, 2.0 / 3.0), p.lerp(q, 2.0 / 3.0), p);
                cur = p;
            },
            else => return error.BadPath,
        }
    }
}

fn num(d: []const u8, i: *usize) !f32 {
    while (i.* < d.len and (d[i.*] == ' ' or d[i.*] == ',')) i.* += 1;
    const s = i.*;
    if (i.* < d.len and (d[i.*] == '-' or d[i.*] == '+')) i.* += 1;
    while (i.* < d.len and (std.ascii.isDigit(d[i.*]) or d[i.*] == '.' or d[i.*] == 'e' or d[i.*] == 'E' or ((d[i.*] == '-' or d[i.*] == '+') and (d[i.* - 1] == 'e' or d[i.* - 1] == 'E')))) i.* += 1;
    if (s == i.*) return error.BadPath;
    return std.fmt.parseFloat(f32, d[s..i.*]) catch error.BadPath;
}

pub fn cubicAt(p0: Vec2, p1: Vec2, p2: Vec2, p3: Vec2, t: f32) Vec2 {
    const u = 1 - t;
    const a = u * u * u;
    const b = 3 * u * u * t;
    const c = 3 * u * t * t;
    const d = t * t * t;
    return .{
        .x = a * p0.x + b * p1.x + c * p2.x + d * p3.x,
        .y = a * p0.y + b * p1.y + c * p2.y + d * p3.y,
    };
}

/// Flattened contours: all points in one list, each contour a range of it.
pub const Polylines = struct {
    points: std.ArrayList(Vec2) = .empty,
    contours: std.ArrayList(Contour) = .empty,
    current_start: u32 = 0,

    pub const Contour = struct {
        start: u32,
        end: u32,
        closed: bool,
    };

    pub fn deinit(self: *Polylines, gpa: std.mem.Allocator) void {
        self.points.deinit(gpa);
        self.contours.deinit(gpa);
    }

    pub fn clear(self: *Polylines) void {
        self.points.clearRetainingCapacity();
        self.contours.clearRetainingCapacity();
    }

    fn begin(self: *Polylines, gpa: std.mem.Allocator, p: Vec2) !void {
        self.current_start = @intCast(self.points.items.len);
        try self.points.append(gpa, p);
    }

    fn push(self: *Polylines, gpa: std.mem.Allocator, p: Vec2) !void {
        try self.points.append(gpa, p);
    }

    fn end(self: *Polylines, gpa: std.mem.Allocator, closed: bool) !void {
        const e: u32 = @intCast(self.points.items.len);
        if (e - self.current_start >= 2) {
            try self.contours.append(gpa, .{
                .start = self.current_start,
                .end = e,
                .closed = closed,
            });
        }
    }

    pub fn contour(self: *const Polylines, c: Contour) []const Vec2 {
        return self.points.items[c.start..c.end];
    }
};

test "affine invert" {
    const m: Affine = .{
        .a = 2,
        .b = 0.5,
        .c = -1,
        .d = 3,
        .e = 10,
        .f = -4,
    };
    const inv = m.invert().?;
    const p = inv.apply(m.apply(.{
        .x = 3,
        .y = 7,
    }));
    try std.testing.expectApproxEqAbs(@as(f32, 3), p.x, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 7), p.y, 1e-4);
}

test "round rect radii clamp" {
    const gpa = std.testing.allocator;
    var p: Path = .{};
    defer p.deinit(gpa);
    try p.addRoundRect(gpa, 10, 4, .{ 100, 100, 100, 100 });
    const b = p.bounds();
    try std.testing.expectEqual(@as(f32, 0), b.x0);
    try std.testing.expectEqual(@as(f32, 10), b.x1);
    try std.testing.expectEqual(@as(f32, 4), b.y1);
}

test "svg path" {
    const gpa = std.testing.allocator;
    var p: Path = .{};
    defer p.deinit(gpa);
    try parseSvgPath(gpa, "M0 -0.5L0 0L1344 0L1344 -1Z M1 2C3 4 5 6 7 8Q9 10 11 12Z", &p);
    try std.testing.expectEqual(@as(usize, 9), p.verbs.items.len);
    try std.testing.expectEqual(@as(f32, 1344), p.points.items[2].x);
}
