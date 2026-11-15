//! Pixel buffers in premultiplied sRGB floats, shaders and compositing.

const std = @import("std");
const geom = @import("geom.zig");
const mask_mod = @import("mask.zig");
const Image = @import("../codec/image.zig").Image;

const Vec2 = geom.Vec2;
const Affine = geom.Affine;
const IRect = mask_mod.IRect;
const Mask = mask_mod.Mask;

pub const Rgba = [4]f32;

/// Premultiplied RGBA floats over `rect` in device pixels.
pub const Pixmap = struct {
    rect: IRect,
    data: []Rgba,

    pub fn init(gpa: std.mem.Allocator, rect: IRect) !Pixmap {
        const data = try gpa.alloc(Rgba, rect.width() * rect.height());
        @memset(data, .{ 0, 0, 0, 0 });
        return .{
            .rect = rect,
            .data = data,
        };
    }

    pub fn deinit(self: *Pixmap, gpa: std.mem.Allocator) void {
        gpa.free(self.data);
        self.* = undefined;
    }

    pub fn row(self: *Pixmap, y: i32) []Rgba {
        const w = self.rect.width();
        return self.data[@as(usize, @intCast(y - self.rect.y0)) * w ..][0..w];
    }

    pub fn at(self: *const Pixmap, x: i32, y: i32) Rgba {
        if (x < self.rect.x0 or y < self.rect.y0 or x >= self.rect.x1 or y >= self.rect.y1) return .{ 0, 0, 0, 0 };
        const w = self.rect.width();
        return self.data[@as(usize, @intCast(y - self.rect.y0)) * w + @as(usize, @intCast(x - self.rect.x0))];
    }

    /// Paints `shader` through `cov` (scaled by `opacity`) with source-over.
    pub fn fillMask(self: *Pixmap, cov: *const Mask, shader: *const Shader, opacity: f32) void {
        self.fillMaskBlend(cov, shader, opacity, .normal);
    }

    /// Paints `shader` through `cov` with a blend mode.
    pub fn fillMaskBlend(self: *Pixmap, cov: *const Mask, shader: *const Shader, opacity: f32, mode: BlendMode) void {
        const r = cov.rect.intersect(self.rect);
        if (r.isEmpty()) return;
        const cw = cov.rect.width();
        var y = r.y0;
        while (y < r.y1) : (y += 1) {
            const dst = self.row(y);
            const src = cov.data[@as(usize, @intCast(y - cov.rect.y0)) * cw ..];
            var x = r.x0;
            while (x < r.x1) : (x += 1) {
                const c = src[@intCast(x - cov.rect.x0)] * opacity;
                if (c <= 0) continue;
                const s = shader.eval(x, y);
                const d = &dst[@intCast(x - self.rect.x0)];
                if (mode == .normal) over(d, s, c) else blendPixel(d, s, c, mode);
            }
        }
    }

    pub const DrawOptions = struct {
        /// Coverage `src` is drawn through; without it, all of `src`.
        clip: ?*const Mask = null,
        mode: BlendMode = .normal,
    };

    /// Draws `src` onto `self`, scaled by `opacity`.
    pub fn drawPixmap(self: *Pixmap, src: *const Pixmap, opacity: f32, options: DrawOptions) void {
        const r = src.rect.intersect(self.rect);
        if (r.isEmpty()) return;
        var y = r.y0;
        while (y < r.y1) : (y += 1) {
            const dst = self.row(y);
            var x = r.x0;
            while (x < r.x1) : (x += 1) {
                var c = opacity;
                if (options.clip) |m| c *= m.at(x, y);
                if (c <= 0) continue;
                const s = src.at(x, y);
                if (s[3] <= 0) continue;
                const d = &dst[@intCast(x - self.rect.x0)];
                if (options.mode == .normal) over(d, s, c) else blendPixel(d, s, c, options.mode);
            }
        }
    }

    /// `self = self + (src - self) * mask`: src replaces self where the mask covers.
    pub fn replaceMasked(self: *Pixmap, src: *const Pixmap, m: *const Mask) void {
        const r = src.rect.intersect(self.rect).intersect(m.rect);
        if (r.isEmpty()) return;
        var y = r.y0;
        while (y < r.y1) : (y += 1) {
            const dst = self.row(y);
            var x = r.x0;
            while (x < r.x1) : (x += 1) {
                const c = m.at(x, y);
                if (c <= 0) continue;
                const s = src.at(x, y);
                const d = &dst[@intCast(x - self.rect.x0)];
                d.* = .{ d[0] + (s[0] - d[0]) * c, d[1] + (s[1] - d[1]) * c, d[2] + (s[2] - d[2]) * c, d[3] + (s[3] - d[3]) * c };
            }
        }
    }

    /// Multiplies every pixel by the mask (outside the mask: cleared).
    pub fn applyMask(self: *Pixmap, m: *const Mask) void {
        var y = self.rect.y0;
        while (y < self.rect.y1) : (y += 1) {
            const dst = self.row(y);
            for (dst, 0..) |*d, i| {
                const c = m.at(self.rect.x0 + @as(i32, @intCast(i)), y);
                d.* = .{ d[0] * c, d[1] * c, d[2] * c, d[3] * c };
            }
        }
    }

    /// Straight-alpha RGBA8 for `rect` (which may reach outside: transparent there).
    pub fn toRgba8(self: *const Pixmap, gpa: std.mem.Allocator, rect: IRect) ![]u8 {
        const out = try gpa.alloc(u8, rect.width() * rect.height() * 4);
        self.writeRgba8(rect, out);
        return out;
    }

    /// `toRgba8` into `out`, which holds `rect.width() * rect.height() * 4` bytes.
    pub fn writeRgba8(self: *const Pixmap, rect: IRect, out: []u8) void {
        const w = rect.width();
        const h = rect.height();
        var y: u32 = 0;
        while (y < h) : (y += 1) {
            var x: u32 = 0;
            while (x < w) : (x += 1) {
                const p = self.at(rect.x0 + @as(i32, @intCast(x)), rect.y0 + @as(i32, @intCast(y)));
                const o = out[(y * w + x) * 4 ..][0..4];
                const a = std.math.clamp(p[3], 0, 1);
                if (a <= 0) {
                    o.* = .{ 0, 0, 0, 0 };
                    continue;
                }
                o[0] = to8(p[0] / a);
                o[1] = to8(p[1] / a);
                o[2] = to8(p[2] / a);
                o[3] = to8(a);
            }
        }
    }
};

fn to8(v: f32) u8 {
    return @intFromFloat(@round(std.math.clamp(v, 0, 1) * 255));
}

pub const BlendMode = enum {
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

/// Composites premultiplied `s` (scaled by coverage `c`) onto `d` with a blend mode, by
/// the W3C compositing model: the blend result shows where both are opaque, each colour
/// alone where only it is.
fn blendPixel(d: *Rgba, s0: Rgba, c: f32, mode: BlendMode) void {
    const s: Rgba = .{ s0[0] * c, s0[1] * c, s0[2] * c, s0[3] * c };
    const sa = s[3];
    const da = d[3];
    if (sa <= 0) return;
    // Linear dodge and burn are Figma's plus-lighter and plus-darker on premultiplied
    // colour (so a translucent source adds or removes only its share).
    if (mode == .linear_dodge or mode == .linear_burn) {
        const ra = @min(1, sa + da);
        for (0..3) |k| {
            d[k] = if (mode == .linear_dodge)
                @min(ra, d[k] + s[k])
            else
                @max(0, ra - ((da - d[k]) + (sa - s[k])));
        }
        d[3] = ra;
        return;
    }
    // Straight colours.
    const cs: [3]f32 = .{ s[0] / sa, s[1] / sa, s[2] / sa };
    const cb: [3]f32 = if (da > 0) .{ d[0] / da, d[1] / da, d[2] / da } else .{ 0, 0, 0 };
    var b: [3]f32 = undefined;
    switch (mode) {
        .hue => b = setLum(setSat(cs, sat(cb)), lum(cb)),
        .saturation => b = setLum(setSat(cb, sat(cs)), lum(cb)),
        .color => b = setLum(cs, lum(cb)),
        .luminosity => b = setLum(cb, lum(cs)),
        else => for (&b, cs, cb) |*o, x, y| {
            o.* = separable(mode, y, x);
        },
    }
    const ra = sa + da - sa * da;
    var out: Rgba = undefined;
    for (0..3) |k| {
        out[k] = s[k] * (1 - da) + d[k] * (1 - sa) + sa * da * std.math.clamp(b[k], 0, 1);
    }
    out[3] = ra;
    d.* = out;
}

/// `cb` backdrop, `cs` source, straight 0..1.
fn separable(mode: BlendMode, cb: f32, cs: f32) f32 {
    return switch (mode) {
        .multiply => cb * cs,
        .screen => cb + cs - cb * cs,
        .overlay => hardLight(cs, cb),
        .darken => @min(cb, cs),
        .lighten => @max(cb, cs),
        .color_dodge => if (cb <= 0) 0 else if (cs >= 1) 1 else @min(1, cb / (1 - cs)),
        .color_burn => if (cb >= 1) 1 else if (cs <= 0) 0 else 1 - @min(1, (1 - cb) / cs),
        .linear_dodge => @min(1, cb + cs),
        .linear_burn => @max(0, cb + cs - 1),
        .hard_light => hardLight(cb, cs),
        // Figma's soft light: the W3C formula with its two branches swapped (measured):
        // a darkening source uses the square-root curve, a lightening one b - b².
        .soft_light => blk: {
            if (cs <= 0.5) {
                const dd = if (cb <= 0.25) ((16 * cb - 12) * cb + 4) * cb else @sqrt(cb);
                break :blk cb + (2 * cs - 1) * (dd - cb);
            }
            break :blk cb + (2 * cs - 1) * (cb - cb * cb);
        },
        .difference => @abs(cb - cs),
        .exclusion => cb + cs - 2 * cb * cs,
        else => cs,
    };
}

fn hardLight(cb: f32, cs: f32) f32 {
    return if (cs <= 0.5) cb * 2 * cs else {
        const t = 2 * cs - 1;
        return cb + t - cb * t;
    };
}

fn lum(c: [3]f32) f32 {
    return 0.3 * c[0] + 0.59 * c[1] + 0.11 * c[2];
}

fn clipColor(c: [3]f32) [3]f32 {
    const l = lum(c);
    const n = @min(c[0], @min(c[1], c[2]));
    const x = @max(c[0], @max(c[1], c[2]));
    var o = c;
    if (n < 0) {
        for (&o) |*v| v.* = l + (v.* - l) * l / (l - n);
    }
    if (x > 1) {
        for (&o) |*v| v.* = l + (v.* - l) * (1 - l) / (x - l);
    }
    return o;
}

fn setLum(c: [3]f32, l: f32) [3]f32 {
    const d = l - lum(c);
    return clipColor(.{ c[0] + d, c[1] + d, c[2] + d });
}

fn sat(c: [3]f32) f32 {
    return @max(c[0], @max(c[1], c[2])) - @min(c[0], @min(c[1], c[2]));
}

fn setSat(c: [3]f32, s: f32) [3]f32 {
    const mx = @max(c[0], @max(c[1], c[2]));
    const mn = @min(c[0], @min(c[1], c[2]));
    var o: [3]f32 = .{ 0, 0, 0 };
    if (mx > mn) {
        for (&o, c) |*v, x| {
            v.* = if (x == mx) s else if (x == mn) 0 else (x - mn) * s / (mx - mn);
        }
    }
    return o;
}

inline fn over(d: *Rgba, s: Rgba, c: f32) void {
    const sa = s[3] * c;
    const k = 1 - sa;
    d.* = .{ s[0] * c + d[0] * k, s[1] * c + d[1] * k, s[2] * c + d[2] * k, sa + d[3] * k };
}

pub fn premultiply(r: f32, g: f32, b: f32, a: f32) Rgba {
    return .{ r * a, g * a, b * a, a };
}

pub const GradientKind = enum {
    linear,
    radial,
    angular,
    diamond,
};

pub const GradientStop = struct {
    at: f32,
    /// Straight (not premultiplied) colour: stops interpolate colour and alpha apart, as
    /// Figma does, and the result is premultiplied after.
    color: Rgba,
};

pub const Shader = union(enum) {
    solid: Rgba,
    gradient: Gradient,
    image: ImageShader,

    pub fn eval(self: *const Shader, x: i32, y: i32) Rgba {
        const p: Vec2 = .{
            .x = @as(f32, @floatFromInt(x)) + 0.5,
            .y = @as(f32, @floatFromInt(y)) + 0.5,
        };
        return switch (self.*) {
            .solid => |c| c,
            .gradient => |*g| g.eval(p),
            .image => |*im| im.eval(p),
        };
    }
};

pub const Gradient = struct {
    kind: GradientKind,
    /// Device space to gradient space (u along start→end, v along start→width handle).
    inverse: Affine,
    stops: []const GradientStop,

    fn eval(self: *const Gradient, p: Vec2) Rgba {
        const g = self.inverse.apply(p);
        const t = switch (self.kind) {
            .linear => g.x,
            .radial => @sqrt(g.x * g.x + g.y * g.y),
            .angular => blk: {
                var a = std.math.atan2(g.y, g.x) / std.math.tau;
                if (a < 0) a += 1;
                break :blk a;
            },
            .diamond => @abs(g.x) + @abs(g.y),
        };
        const c = sampleStops(self.stops, t);
        return premultiply(c[0], c[1], c[2], c[3]);
    }
};

fn sampleStops(stops: []const GradientStop, t: f32) Rgba {
    if (stops.len == 0) return .{ 0, 0, 0, 0 };
    if (t <= stops[0].at) return stops[0].color;
    for (stops[1..], 1..) |s, i| {
        if (t <= s.at) {
            const a = stops[i - 1];
            const span = s.at - a.at;
            const k = if (span <= 0) 1 else (t - a.at) / span;
            return .{
                a.color[0] + (s.color[0] - a.color[0]) * k,
                a.color[1] + (s.color[1] - a.color[1]) * k,
                a.color[2] + (s.color[2] - a.color[2]) * k,
                a.color[3] + (s.color[3] - a.color[3]) * k,
            };
        }
    }
    return stops[stops.len - 1].color;
}

/// An image as a mip chain of 8-bit RGBA: level 0 is the decoded pixels as they are
/// (straight alpha), the smaller levels are averaged in premultiplied floats and kept
/// premultiplied, rounded to 8 bits. A texel reads back as premultiplied floats.
///
/// A chain may start below the image's full size (`dropFinest`, for an image only ever
/// drawn small): `levels[0]` is then level `first` of the full chain, and `width` and
/// `height` keep the image's own size, which placing the image goes by.
pub const Mipmap = struct {
    levels: []Level,
    /// The image's own size in pixels (level 0 of the full chain).
    width: u32 = 0,
    height: u32 = 0,
    /// Levels of the full chain left out above `levels[0]`.
    first: u8 = 0,

    pub const Level = struct {
        w: u32,
        h: u32,
        /// `w * h * 4` bytes, R G B A.
        data: []u8,
        /// Level 0: straight alpha; the rest premultiplied.
        straight: bool,

        pub fn texel(self: Level, i: usize) Rgba {
            const s = self.data[i * 4 ..][0..4];
            const a = @as(f32, @floatFromInt(s[3])) / 255;
            if (self.straight) return .{
                @as(f32, @floatFromInt(s[0])) / 255 * a,
                @as(f32, @floatFromInt(s[1])) / 255 * a,
                @as(f32, @floatFromInt(s[2])) / 255 * a,
                a,
            };
            return .{
                @as(f32, @floatFromInt(s[0])) / 255,
                @as(f32, @floatFromInt(s[1])) / 255,
                @as(f32, @floatFromInt(s[2])) / 255,
                a,
            };
        }
    };

    /// Builds the chain; takes over `img`'s pixels as level 0 (the image is left empty).
    pub fn init(gpa: std.mem.Allocator, img: *Image) !Mipmap {
        var list: std.ArrayList(Level) = .empty;
        errdefer {
            for (list.items) |l| gpa.free(l.data);
            list.deinit(gpa);
        }
        try list.append(gpa, .{
            .w = img.width,
            .h = img.height,
            .data = img.pixels,
            .straight = true,
        });
        img.pixels = &.{};
        // Each level is averaged in floats from the texels of the one above (level 0's
        // exact; the smaller ones' rounded to 8 bits), so no float copy is kept.
        while (true) {
            const above = list.items[list.items.len - 1];
            const pw = above.w;
            const ph = above.h;
            if (pw <= 1 and ph <= 1) break;
            const w = @max(1, pw / 2);
            const h = @max(1, ph / 2);
            const packed_level = try gpa.alloc(u8, w * h * 4);
            errdefer gpa.free(packed_level);
            var y: u32 = 0;
            while (y < h) : (y += 1) {
                var x: u32 = 0;
                while (x < w) : (x += 1) {
                    var acc: Rgba = .{ 0, 0, 0, 0 };
                    var n: f32 = 0;
                    for ([_]u32{ 0, 1 }) |dy| for ([_]u32{ 0, 1 }) |dx| {
                        const sx = @min(pw - 1, x * 2 + dx);
                        const sy = @min(ph - 1, y * 2 + dy);
                        const t = above.texel(sy * pw + sx);
                        inline for (0..4) |k| acc[k] += t[k];
                        n += 1;
                    };
                    inline for (0..4) |k| packed_level[(y * w + x) * 4 + k] = to8(acc[k] / n);
                }
            }
            try list.append(gpa, .{
                .w = w,
                .h = h,
                .data = packed_level,
                .straight = false,
            });
        }
        // Level 0's size before the list hands its items over.
        const width = list.items[0].w;
        const height = list.items[0].h;
        return .{
            .levels = try list.toOwnedSlice(gpa),
            .width = width,
            .height = height,
        };
    }

    /// Frees the `k` finest levels (keeping at least the coarsest): the image then draws
    /// the same at any size that reads only the levels kept.
    pub fn dropFinest(self: *Mipmap, gpa: std.mem.Allocator, k: u8) void {
        const n: usize = @min(k, self.levels.len - 1);
        if (n == 0) return;
        // Out of memory for the shorter list: keep every level.
        const kept = gpa.dupe(Level, self.levels[n..]) catch return;
        for (self.levels[0..n]) |l| gpa.free(l.data);
        gpa.free(self.levels);
        self.levels = kept;
        self.first += @intCast(n);
    }

    /// The chain as bytes another engine takes (`unpack`): little-endian u32 width,
    /// height, first and the level count, then each level's w, h and straight, then the
    /// levels' texels in order.
    pub fn pack(self: *const Mipmap, gpa: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
        const head = 4 + 3 * self.levels.len;
        try out.ensureTotalCapacity(gpa, out.items.len + head * 4 + self.bytes());
        const put = struct {
            fn f(o: *std.ArrayList(u8), v: u32) void {
                var b: [4]u8 = undefined;
                std.mem.writeInt(u32, &b, v, .little);
                o.appendSliceAssumeCapacity(&b);
            }
        }.f;
        put(out, self.width);
        put(out, self.height);
        put(out, self.first);
        put(out, @intCast(self.levels.len));
        for (self.levels) |l| {
            put(out, l.w);
            put(out, l.h);
            put(out, @intFromBool(l.straight));
        }
        for (self.levels) |l| out.appendSliceAssumeCapacity(l.data);
    }

    /// A chain from `pack`'s bytes (copied).
    pub fn unpack(gpa: std.mem.Allocator, b: []const u8) !Mipmap {
        const get = struct {
            fn f(s: []const u8, i: usize) !u32 {
                if (s.len < (i + 1) * 4) return error.BadMipmap;
                return std.mem.readInt(u32, s[i * 4 ..][0..4], .little);
            }
        }.f;
        const count = try get(b, 3);
        if (count == 0 or count > 32) return error.BadMipmap;
        const levels = try gpa.alloc(Level, count);
        var made: usize = 0;
        errdefer {
            for (levels[0..made]) |l| gpa.free(l.data);
            gpa.free(levels);
        }
        var at: usize = (4 + 3 * count) * 4;
        for (levels, 0..) |*l, i| {
            const w = try get(b, 4 + 3 * i);
            const h = try get(b, 5 + 3 * i);
            const n = @as(usize, w) * h * 4;
            if (b.len < at + n) return error.BadMipmap;
            l.* = .{
                .w = w,
                .h = h,
                .data = try gpa.dupe(u8, b[at..][0..n]),
                .straight = try get(b, 6 + 3 * i) != 0,
            };
            made += 1;
            at += n;
        }
        return .{
            .levels = levels,
            .width = try get(b, 0),
            .height = try get(b, 1),
            .first = @intCast(try get(b, 2)),
        };
    }

    /// Bytes the chain holds.
    pub fn bytes(self: *const Mipmap) usize {
        var n: usize = 0;
        for (self.levels) |l| n += l.data.len;
        return n;
    }

    pub fn deinit(self: *Mipmap, gpa: std.mem.Allocator) void {
        for (self.levels) |l| gpa.free(l.data);
        gpa.free(self.levels);
        self.* = undefined;
    }
};

pub const ImageShader = struct {
    mip: *const Mipmap,
    /// Device space to image pixel space (level 0).
    inverse: Affine,
    tile: bool = false,
    /// Transparent outside the image (instead of repeating its edge).
    decal: bool = false,
    /// Image pixels per device pixel; picks the mip level.
    footprint: f32,

    fn eval(self: *const ImageShader, p: Vec2) Rgba {
        const q = self.inverse.apply(p);
        if (self.decal) {
            const b = self.mip.levels[0];
            if (q.x < 0 or q.y < 0 or q.x > @as(f32, @floatFromInt(b.w)) or q.y > @as(f32, @floatFromInt(b.h))) return .{ 0, 0, 0, 0 };
        }
        // The device pixel's extent in image pixels (the box around its parallelogram).
        const ex = @abs(self.inverse.a) + @abs(self.inverse.c);
        const ey = @abs(self.inverse.b) + @abs(self.inverse.d);
        // Shrunk, an image is the average of the image pixels under each device pixel
        // (Figma's exports match an area average, not a trilinear mip); enlarged or at
        // its size, bilinear.
        if (@max(ex, ey) > 1) return self.boxAverage(q, ex, ey);
        return self.sampleLevel(0, q);
    }

    /// Texels per side a box average reads at most (a coarser level past it).
    pub const box_span: f32 = 16;

    /// The mip level a box average of `ex` x `ey` image pixels reads: one whose texels
    /// are at most a quarter of the box's shorter side (its edges then cut texels finely
    /// enough to match an average of the image's own pixels), coarser while the longer
    /// side spans more than `box_span` texels.
    pub fn boxLevel(levels: usize, ex: f32, ey: f32) usize {
        var level: usize = @intFromFloat(@max(0, @floor(std.math.log2(@max(@min(ex, ey) / 4, 1)))));
        level = @min(level, levels - 1);
        while (level + 1 < levels and @max(ex, ey) / std.math.pow(f32, 2, @floatFromInt(level)) > box_span) level += 1;
        return level;
    }

    /// The average over the `ex` x `ey` box (image pixels) centred on `q0`, read from
    /// the level `boxLevel` picks, each texel weighted by its overlap with the box.
    fn boxAverage(self: *const ImageShader, q0: Vec2, ex: f32, ey: f32) Rgba {
        const level = boxLevel(self.mip.levels.len, ex, ey);
        const lv = self.mip.levels[level];
        const base = self.mip.levels[0];
        const sx = @as(f32, @floatFromInt(lv.w)) / @as(f32, @floatFromInt(base.w));
        const sy = @as(f32, @floatFromInt(lv.h)) / @as(f32, @floatFromInt(base.h));
        const cx = q0.x * sx;
        const cy = q0.y * sy;
        const hw = @max(0.5, ex * sx / 2);
        const hh = @max(0.5, ey * sy / 2);
        const x0 = cx - hw;
        const x1 = cx + hw;
        const y0 = cy - hh;
        const y1 = cy + hh;
        const ix0: i64 = @intFromFloat(std.math.clamp(@floor(x0), -1e9, 1e9));
        const ix1: i64 = @intFromFloat(std.math.clamp(@ceil(x1), -1e9, 1e9));
        const iy0: i64 = @intFromFloat(std.math.clamp(@floor(y0), -1e9, 1e9));
        const iy1: i64 = @intFromFloat(std.math.clamp(@ceil(y1), -1e9, 1e9));
        var acc: Rgba = .{ 0, 0, 0, 0 };
        var iy = iy0;
        while (iy < iy1) : (iy += 1) {
            const fy: f32 = @floatFromInt(iy);
            const wy = @min(y1, fy + 1) - @max(y0, fy);
            if (wy <= 0) continue;
            var ix = ix0;
            while (ix < ix1) : (ix += 1) {
                const fx: f32 = @floatFromInt(ix);
                const wx = @min(x1, fx + 1) - @max(x0, fx);
                if (wx <= 0) continue;
                const t = self.texel(lv, ix, iy);
                inline for (0..4) |k| acc[k] += t[k] * wx * wy;
            }
        }
        const area = (x1 - x0) * (y1 - y0);
        inline for (0..4) |k| acc[k] /= area;
        return acc;
    }

    fn sampleLevel(self: *const ImageShader, level: usize, q0: Vec2) Rgba {
        const lv = self.mip.levels[level];
        const base = self.mip.levels[0];
        const sx = @as(f32, @floatFromInt(lv.w)) / @as(f32, @floatFromInt(base.w));
        const sy = @as(f32, @floatFromInt(lv.h)) / @as(f32, @floatFromInt(base.h));
        const fx = q0.x * sx - 0.5;
        const fy = q0.y * sy - 0.5;
        const x0f = @floor(fx);
        const y0f = @floor(fy);
        const tx = fx - x0f;
        const ty = fy - y0f;
        const x0: i64 = @intFromFloat(std.math.clamp(x0f, -1e9, 1e9));
        const y0: i64 = @intFromFloat(std.math.clamp(y0f, -1e9, 1e9));
        const p00 = self.texel(lv, x0, y0);
        const p10 = self.texel(lv, x0 + 1, y0);
        const p01 = self.texel(lv, x0, y0 + 1);
        const p11 = self.texel(lv, x0 + 1, y0 + 1);
        var out: Rgba = undefined;
        inline for (0..4) |k| {
            const top = p00[k] + (p10[k] - p00[k]) * tx;
            const bot = p01[k] + (p11[k] - p01[k]) * tx;
            out[k] = top + (bot - top) * ty;
        }
        return out;
    }

    fn texel(self: *const ImageShader, lv: Mipmap.Level, x: i64, y: i64) Rgba {
        const w: i64 = lv.w;
        const h: i64 = lv.h;
        var xx = x;
        var yy = y;
        if (self.tile) {
            xx = @mod(xx, w);
            yy = @mod(yy, h);
        } else {
            xx = std.math.clamp(xx, 0, w - 1);
            yy = std.math.clamp(yy, 0, h - 1);
        }
        return lv.texel(@intCast(yy * w + xx));
    }
};

/// Gaussian blur of the alpha-only buffer `a` (`w` x `h`) in place, standard deviation
/// `sigma`. Small blurs use the exact kernel; larger ones three box passes, which match a
/// Gaussian closely at a cost independent of the radius.
pub fn blurAlpha(gpa: std.mem.Allocator, a: []f32, w: u32, h: u32, sigma: f32) !void {
    if (sigma < 0.05) return;
    const tmp = try gpa.alloc(f32, @max(w, h) * 2);
    defer gpa.free(tmp);
    if (sigma <= exact_blur_limit) {
        const radius: usize = @intFromFloat(@ceil(sigma * 3));
        var kbuf: [2 * 3 * exact_blur_limit + 3]f32 = undefined;
        const kernel = kbuf[0 .. radius * 2 + 1];
        var sum: f32 = 0;
        for (kernel, 0..) |*k, i| {
            const d = @as(f32, @floatFromInt(i)) - @as(f32, @floatFromInt(radius));
            k.* = @exp(-(d * d) / (2 * sigma * sigma));
            sum += k.*;
        }
        for (kernel) |*k| k.* /= sum;
        var y: usize = 0;
        while (y < h) : (y += 1) convolve(a[y * w ..], 1, w, kernel, radius, tmp);
        const out = try gpa.alloc(f32, a.len);
        defer gpa.free(out);
        convolveColumns(a, out, w, h, kernel, radius);
        return;
    }
    const boxes = boxSizes(sigma);
    const out = try gpa.alloc(f32, a.len);
    defer gpa.free(out);
    const acc = try gpa.alloc(f64, w);
    defer gpa.free(acc);
    for (boxes) |r| {
        var y: usize = 0;
        while (y < h) : (y += 1) boxLine(a[y * w ..], 1, w, r, tmp);
        boxColumns(a, out, acc, w, h, r);
    }
}

/// `boxLine` down every column at once, sweeping rows (the same sums in the same order
/// per column, without striding through memory a column at a time).
fn boxColumns(a: []f32, out: []f32, acc: []f64, w: usize, h: usize, r: usize) void {
    if (r == 0) return;
    const inv = 1 / @as(f32, @floatFromInt(2 * r + 1));
    @memset(acc, 0);
    var i: usize = 0;
    while (i < @min(r, h)) : (i += 1) {
        for (acc, a[i * w ..][0..w]) |*s, v| s.* += v;
    }
    i = 0;
    while (i < h) : (i += 1) {
        if (i + r < h) for (acc, a[(i + r) * w ..][0..w]) |*s, v| {
            s.* += v;
        };
        if (i > r) for (acc, a[(i - r - 1) * w ..][0..w]) |*s, v| {
            s.* -= v;
        };
        for (out[i * w ..][0..w], acc) |*o, s| o.* = @floatCast(s * inv);
    }
    @memcpy(a, out);
}

/// `convolve` down every column at once, sweeping rows.
fn convolveColumns(a: []f32, out: []f32, w: usize, h: usize, kernel: []const f32, radius: usize) void {
    var i: usize = 0;
    while (i < h) : (i += 1) {
        const o = out[i * w ..][0..w];
        @memset(o, 0);
        const lo = if (i >= radius) 0 else radius - i;
        const hi = @min(kernel.len, h + radius - i);
        var k = lo;
        while (k < hi) : (k += 1) {
            const kv = kernel[k];
            for (o, a[(i + k - radius) * w ..][0..w]) |*d, v| d.* += kv * v;
        }
    }
    @memcpy(a, out);
}

/// Gaussian blur of every channel of premultiplied pixels (`w` x `h`) in place.
pub fn blurRgba(gpa: std.mem.Allocator, px: []Rgba, w: u32, h: u32, sigma: f32) !void {
    if (sigma < 0.05) return;
    const ch = try gpa.alloc(f32, px.len);
    defer gpa.free(ch);
    for (0..4) |k| {
        for (px, ch) |p, *c| c.* = p[k];
        try blurAlpha(gpa, ch, w, h, sigma);
        for (px, ch) |*p, c| p[k] = c;
    }
}

/// Blurs up to this standard deviation use the exact Gaussian; larger ones three boxes.
pub const exact_blur_limit = 24;

/// Half-widths of three box filters whose combination has standard deviation `sigma`.
pub fn boxSizes(sigma: f32) [3]usize {
    const n: f32 = 3;
    const ideal = @sqrt(12 * sigma * sigma / n + 1);
    var wl = @floor(ideal);
    if (@mod(wl, 2) == 0) wl -= 1;
    const wu = wl + 2;
    const mf = (12 * sigma * sigma - n * wl * wl - 4 * n * wl - 3 * n) / (-4 * wl - 4);
    const mm = @round(mf);
    var out: [3]usize = undefined;
    for (&out, 0..) |*o, i| {
        const width = if (@as(f32, @floatFromInt(i)) < mm) wl else wu;
        o.* = @intFromFloat(@max(0, (width - 1) / 2));
    }
    return out;
}

/// Box average of half-width `r` along one line, zero outside.
fn boxLine(buf: []f32, stride: usize, n: usize, r: usize, tmp: []f32) void {
    if (r == 0) return;
    const inv = 1 / @as(f32, @floatFromInt(2 * r + 1));
    var acc: f64 = 0;
    var i: usize = 0;
    while (i < @min(r, n)) : (i += 1) acc += buf[i * stride];
    i = 0;
    while (i < n) : (i += 1) {
        if (i + r < n) acc += buf[(i + r) * stride];
        if (i > r) acc -= buf[(i - r - 1) * stride];
        tmp[i] = @floatCast(acc * inv);
    }
    i = 0;
    while (i < n) : (i += 1) buf[i * stride] = tmp[i];
}

fn convolve(buf: []f32, stride: usize, n: usize, kernel: []const f32, radius: usize, tmp: []f32) void {
    var i: usize = 0;
    while (i < n) : (i += 1) {
        var acc: f32 = 0;
        const lo = if (i >= radius) 0 else radius - i;
        const hi = @min(kernel.len, n + radius - i);
        var k = lo;
        while (k < hi) : (k += 1) acc += kernel[k] * buf[(i + k - radius) * stride];
        tmp[i] = acc;
    }
    i = 0;
    while (i < n) : (i += 1) buf[i * stride] = tmp[i];
}

/// Grows (`d` > 0) or shrinks (`d` < 0) the alpha buffer by `d` pixels with a square
/// max/min filter, fractional part blended.
pub fn spreadAlpha(gpa: std.mem.Allocator, a: []f32, w: u32, h: u32, d: f32) !void {
    if (@abs(d) < 0.01) return;
    const grow = d > 0;
    const whole: usize = @intFromFloat(@floor(@abs(d)));
    const frac = @abs(d) - @floor(@abs(d));
    const lo_buf = try gpa.dupe(f32, a);
    defer gpa.free(lo_buf);
    try morph(gpa, lo_buf, w, h, whole, grow);
    if (frac > 0) {
        const hi_buf = try gpa.dupe(f32, a);
        defer gpa.free(hi_buf);
        try morph(gpa, hi_buf, w, h, whole + 1, grow);
        for (a, lo_buf, hi_buf) |*o, l, hv| o.* = l + (hv - l) * frac;
    } else {
        @memcpy(a, lo_buf);
    }
}

fn morph(gpa: std.mem.Allocator, a: []f32, w: u32, h: u32, r: usize, grow: bool) !void {
    if (r == 0) return;
    const n = @max(w, h);
    const tmp = try gpa.alloc(f32, (n + 2 * r) * 3);
    defer gpa.free(tmp);
    var y: usize = 0;
    while (y < h) : (y += 1) morphLine(a[y * w ..], 1, w, r, grow, tmp);
    var x: usize = 0;
    while (x < w) : (x += 1) morphLine(a[x..], w, h, r, grow, tmp);
}

/// Running max (grow) or min (shrink) over a window of `2r + 1` (van Herk / Gil-Werman:
/// constant cost per pixel). Outside the line counts as empty.
fn morphLine(buf: []f32, stride: usize, n: usize, r: usize, grow: bool, tmp: []f32) void {
    const k = 2 * r + 1;
    const len = n + 2 * r;
    const padded = tmp[0..len];
    const g = tmp[len .. 2 * len];
    const hb = tmp[2 * len .. 3 * len];
    for (padded, 0..) |*p, i| p.* = if (i < r or i >= r + n) 0 else buf[(i - r) * stride];
    const pick = struct {
        fn f(gr: bool, a: f32, b: f32) f32 {
            return if (gr) @max(a, b) else @min(a, b);
        }
    }.f;
    var i: usize = 0;
    while (i < len) : (i += 1) {
        g[i] = if (i % k == 0) padded[i] else pick(grow, g[i - 1], padded[i]);
    }
    var j: usize = len;
    while (j > 0) {
        j -= 1;
        hb[j] = if (j == len - 1 or (j + 1) % k == 0) padded[j] else pick(grow, hb[j + 1], padded[j]);
    }
    i = 0;
    while (i < n) : (i += 1) buf[i * stride] = pick(grow, hb[i], g[i + 2 * r]);
}

test "blur keeps total" {
    const gpa = std.testing.allocator;
    var a = [_]f32{0} ** 64;
    a[27] = 1;
    try blurAlpha(gpa, &a, 8, 8, 1);
    var s: f32 = 0;
    for (a) |v| s += v;
    try std.testing.expectApproxEqAbs(@as(f32, 1), s, 1e-3);
}

test "box blur matches gaussian spread" {
    const gpa = std.testing.allocator;
    var a = [_]f32{0} ** 401;
    a[200] = 1;
    try blurAlpha(gpa, &a, 401, 1, 20);
    var mean: f32 = 0;
    var total: f32 = 0;
    for (a, 0..) |v, i| {
        total += v;
        mean += v * @as(f32, @floatFromInt(i));
    }
    mean /= total;
    var variance: f32 = 0;
    for (a, 0..) |v, i| {
        const d = @as(f32, @floatFromInt(i)) - mean;
        variance += v * d * d;
    }
    variance /= total;
    try std.testing.expectApproxEqAbs(@as(f32, 20), @sqrt(variance), 0.6);
}

test "morph grows by r" {
    const gpa = std.testing.allocator;
    var a = [_]f32{0} ** 21;
    a[10] = 1;
    try spreadAlpha(gpa, &a, 21, 1, 3);
    try std.testing.expectEqual(@as(f32, 1), a[7]);
    try std.testing.expectEqual(@as(f32, 1), a[13]);
    try std.testing.expectEqual(@as(f32, 0), a[6]);
    // Shrinking a 9x9 square by 2 leaves 5x5.
    var b = [_]f32{0} ** (11 * 11);
    for (1..10) |y| for (1..10) |x| {
        b[y * 11 + x] = 1;
    };
    try spreadAlpha(gpa, &b, 11, 11, -2);
    try std.testing.expectEqual(@as(f32, 1), b[3 * 11 + 3]);
    try std.testing.expectEqual(@as(f32, 0), b[2 * 11 + 3]);
}

test "blurring columns row by row matches blurring each column" {
    const gpa = std.testing.allocator;
    var prng: std.Random.DefaultPrng = .init(3);
    const rnd = prng.random();
    const w = 37;
    const h = 53;
    for ([_]f32{ 1.3, 7, 30, 61 }) |sigma| {
        const a = try gpa.alloc(f32, w * h);
        defer gpa.free(a);
        for (a) |*v| v.* = if (rnd.boolean()) rnd.float(f32) else 0;
        const b = try gpa.dupe(f32, a);
        defer gpa.free(b);
        try blurAlpha(gpa, a, w, h, sigma);
        // The reference: each column on its own, as lines.
        const tmp = try gpa.alloc(f32, @max(w, h) * 2);
        defer gpa.free(tmp);
        if (sigma <= exact_blur_limit) {
            const radius: usize = @intFromFloat(@ceil(sigma * 3));
            var kbuf: [2 * 3 * exact_blur_limit + 3]f32 = undefined;
            const kernel = kbuf[0 .. radius * 2 + 1];
            var sum: f32 = 0;
            for (kernel, 0..) |*k, i| {
                const d = @as(f32, @floatFromInt(i)) - @as(f32, @floatFromInt(radius));
                k.* = @exp(-(d * d) / (2 * sigma * sigma));
                sum += k.*;
            }
            for (kernel) |*k| k.* /= sum;
            for (0..h) |y| convolve(b[y * w ..], 1, w, kernel, radius, tmp);
            for (0..w) |x| convolve(b[x..], w, h, kernel, radius, tmp);
        } else {
            for (boxSizes(sigma)) |r| {
                for (0..h) |y| boxLine(b[y * w ..], 1, w, r, tmp);
                for (0..w) |x| boxLine(b[x..], w, h, r, tmp);
            }
        }
        try std.testing.expectEqualSlices(f32, b, a);
    }
}
