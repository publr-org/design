//! Effects beyond plain shadows and blurs: progressive blurs, noise grain, edge texture,
//! and the opaque silhouette drop shadows are cast from. Each model was measured on
//! Figma's renders of the "12 — Effects" board; the grain is our own (Figma's random
//! generator is not reproducible), matched in size, coverage, colour and smoothness.

const std = @import("std");
const m = @import("../pubd/model.zig");
const geom = @import("../raster/geom.zig");
const mask_mod = @import("../raster/mask.zig");
const pix = @import("../raster/pixmap.zig");
const colour = @import("colour.zig");

const Affine = geom.Affine;
const Vec2 = geom.Vec2;
const IRect = mask_mod.IRect;
const Pixmap = pix.Pixmap;
const Rgba = pix.Rgba;

// Progressive blur ---------------------------------------------------------------------

/// The largest radius a blur reaches anywhere on the node.
pub fn blurReach(e: m.Effect) f32 {
    const p = e.progressive orelse return e.radius;
    return @max(e.radius, p.start_radius);
}

/// The standard deviation of a progressive blur at each device position.
const Ramp = struct {
    /// Device space to node space.
    inv: Affine,
    /// The ramp's start and its run to the end, in node units.
    start: Vec2,
    dir: Vec2,
    len2: f32,
    /// Device standard deviations at the start and the end.
    s0: f32,
    s1: f32,

    fn init(n: *const m.Node, e: m.Effect, ctm: Affine, k: f32) ?Ramp {
        const p = e.progressive orelse return null;
        const inv = ctm.invert() orelse return null;
        const start: Vec2 = .{
            .x = p.start.x * n.size.x,
            .y = p.start.y * n.size.y,
        };
        const end: Vec2 = .{
            .x = p.end.x * n.size.x,
            .y = p.end.y * n.size.y,
        };
        const dir = end.sub(start);
        const s = ctm.maxScale() * k;
        return .{
            .inv = inv,
            .start = start,
            .dir = dir,
            .len2 = dir.x * dir.x + dir.y * dir.y,
            .s0 = p.start_radius * s,
            .s1 = e.radius * s,
        };
    }

    /// Sigma at device point (x, y): linear along the ramp, held beyond its ends.
    fn sigma(self: *const Ramp, x: f32, y: f32) f32 {
        if (self.len2 <= 1e-9) return self.s1;
        const q = self.inv.apply(.{
            .x = x,
            .y = y,
        }).sub(self.start);
        const t = std.math.clamp((q.x * self.dir.x + q.y * self.dir.y) / self.len2, 0, 1);
        return self.s0 + (self.s1 - self.s0) * t;
    }
};

/// Blur kernels end at this many standard deviations: Figma's blurs stop at the blur
/// radius itself (sigma = 0.4375 x radius, so 1 / 0.4375 sigmas), where an exact
/// Gaussian would still leave a faint tail.
pub var blur_reach: f32 = 1.0 / 0.4375;

/// Normalised, truncated Gaussian kernels by sigma, in steps of 1/16 px.
const Kernels = struct {
    gpa: std.mem.Allocator,
    map: std.AutoHashMapUnmanaged(u32, []f32) = .empty,

    fn deinit(self: *Kernels) void {
        var it = self.map.valueIterator();
        while (it.next()) |k| self.gpa.free(k.*);
        self.map.deinit(self.gpa);
    }

    fn get(self: *Kernels, sigma: f32) ![]const f32 {
        const q: u32 = @intFromFloat(@round(@max(sigma, 0) * 16));
        if (self.map.get(q)) |k| return k;
        const s = @as(f32, @floatFromInt(q)) / 16;
        const r: usize = if (s < 0.05) 0 else @intFromFloat(@max(1, @round(s * blur_reach)));
        const k = try self.gpa.alloc(f32, 2 * r + 1);
        if (r == 0) {
            k[0] = 1;
        } else {
            var sum: f32 = 0;
            for (k, 0..) |*v, i| {
                const d = @as(f32, @floatFromInt(i)) - @as(f32, @floatFromInt(r));
                v.* = @exp(-(d * d) / (2 * s * s));
                sum += v.*;
            }
            for (k) |*v| v.* /= sum;
        }
        try self.map.put(self.gpa, q, k);
        return k;
    }
};

/// Gathers one output pixel along a line of `src` (`len` pixels, `stride` apart) with
/// `kernel` centred on `at`; pixels past the ends count as transparent.
fn gather(src: []const Rgba, stride: usize, len: usize, at: usize, kernel: []const f32) Rgba {
    const r = kernel.len / 2;
    var acc: Rgba = .{ 0, 0, 0, 0 };
    const lo = if (at >= r) at - r else 0;
    const hi = @min(len, at + r + 1);
    var i = lo;
    while (i < hi) : (i += 1) {
        const wt = kernel[i + r - at];
        const p = src[i * stride];
        inline for (0..4) |c| acc[c] += p[c] * wt;
    }
    return acc;
}

/// Index `i` reflected into `lo..hi` (edge pixel not repeated): background blurs read
/// what lies past the node's bounds as a mirror image of what lies inside (measured on
/// a glass card over a disc: the edge row repeated reads too little of the disc).
pub fn mirror(i: i32, lo: i32, hi: i32) i32 {
    if (hi <= lo) return lo;
    var v = i;
    if (v < lo) v = lo + (lo - v - 1);
    if (v >= hi) v = hi - 1 - (v - hi);
    return std.math.clamp(v, lo, hi - 1);
}

/// Blurs `img` with one standard deviation (Figma's truncated kernel); large blurs fall
/// back to the box approximation.
pub fn blur(gpa: std.mem.Allocator, img: *Pixmap, sigma: f32) !void {
    if (sigma > 24) return pix.blurRgba(gpa, img.data, img.rect.width(), img.rect.height(), sigma);
    const w: usize = img.rect.width();
    const h: usize = img.rect.height();
    if (w == 0 or h == 0 or sigma < 0.05) return;
    var kernels: Kernels = .{
        .gpa = gpa,
    };
    defer kernels.deinit();
    const kernel = try kernels.get(sigma);
    const tmp = try gpa.alloc(Rgba, w * h);
    defer gpa.free(tmp);
    for (0..h) |y| {
        const row = img.data[y * w ..];
        for (0..w) |x| tmp[y * w + x] = gather(row, 1, w, x, kernel);
    }
    for (0..w) |x| {
        const col = tmp[x..];
        for (0..h) |y| img.data[y * w + x] = gather(col, w, h, y, kernel);
    }
}

/// Blurs `img` with a standard deviation that changes across the node. Measured on
/// Figma's renders: sigma runs linearly from `start_radius` at `start` to `radius` at
/// `end` (both in the node's box), by projection on the line between them, held beyond
/// either end; the node's own edges smear with the local sigma. Each output pixel
/// gathers with the Gaussian of its own sigma, rows then columns.
pub fn progressiveBlur(gpa: std.mem.Allocator, img: *Pixmap, n: *const m.Node, e: m.Effect, ctm: Affine, k: f32) !void {
    const ramp = Ramp.init(n, e, ctm, k) orelse return;
    const w: usize = img.rect.width();
    const h: usize = img.rect.height();
    if (w == 0 or h == 0) return;
    const sig = try gpa.alloc(f32, w * h);
    defer gpa.free(sig);
    for (0..h) |y| {
        for (0..w) |x| {
            const dx = @as(f32, @floatFromInt(img.rect.x0 + @as(i32, @intCast(x)))) + 0.5;
            const dy = @as(f32, @floatFromInt(img.rect.y0 + @as(i32, @intCast(y)))) + 0.5;
            sig[y * w + x] = ramp.sigma(dx, dy);
        }
    }
    var kernels: Kernels = .{
        .gpa = gpa,
    };
    defer kernels.deinit();
    const tmp = try gpa.alloc(Rgba, w * h);
    defer gpa.free(tmp);
    for (0..h) |y| {
        const row = img.data[y * w ..];
        for (0..w) |x| tmp[y * w + x] = gather(row, 1, w, x, try kernels.get(sig[y * w + x]));
    }
    for (0..w) |x| {
        const col = tmp[x..];
        for (0..h) |y| img.data[y * w + x] = gather(col, w, h, y, try kernels.get(sig[y * w + x]));
    }
}

// Grain ---------------------------------------------------------------------------------

/// A well-mixed 32-bit hash of a lattice point and a seed.
fn hash(x: i32, y: i32, seed: u32) u32 {
    var v: u32 = @as(u32, @bitCast(x)) *% 0x8da6b343;
    v ^= @as(u32, @bitCast(y)) *% 0xd8163841;
    v ^= seed *% 0xcb1ab31f;
    v ^= v >> 16;
    v *%= 0x7feb352d;
    v ^= v >> 15;
    v *%= 0x846ca68b;
    v ^= v >> 16;
    return v;
}

fn unit(v: u32) f32 {
    return @as(f32, @floatFromInt(v >> 8)) / 16777216.0;
}

/// Value noise in 0..1 at `p` (lattice units): a random value per lattice point,
/// smoothstep-interpolated between them. The lattice is turned off the pixel grid so
/// grains do not line up with pixels (which shows once pixels average several samples).
fn valueNoise(p0: Vec2, seed: u32) f32 {
    const p: Vec2 = .{
        .x = p0.x * lattice_cos - p0.y * lattice_sin,
        .y = p0.x * lattice_sin + p0.y * lattice_cos,
    };
    const fx = @floor(p.x);
    const fy = @floor(p.y);
    const ix: i32 = @intFromFloat(std.math.clamp(fx, -1e9, 1e9));
    const iy: i32 = @intFromFloat(std.math.clamp(fy, -1e9, 1e9));
    var tx = p.x - fx;
    var ty = p.y - fy;
    tx = tx * tx * (3 - 2 * tx);
    ty = ty * ty * (3 - 2 * ty);
    const a = unit(hash(ix, iy, seed));
    const b = unit(hash(ix +% 1, iy, seed));
    const c = unit(hash(ix, iy +% 1, seed));
    const d = unit(hash(ix +% 1, iy +% 1, seed));
    const top = a + (b - a) * tx;
    const bot = c + (d - c) * tx;
    return top + (bot - top) * ty;
}

/// The noise lattice's turn against the node's axes (about 34 degrees).
const lattice_cos: f32 = 0.8253356;
const lattice_sin: f32 = 0.5646425;

/// Lattice spacing per unit of grain size: grains are about half the noise size across
/// (Figma's grain correlation falls to zero about one grain size apart).
pub var grain_cell: f32 = 0.55;
/// Threshold drop per unit of density (a density of 0.5 covers 8.5% of the node, as in
/// Figma's renders), and the field span over which a grain's edge fades.
pub var grain_density_k: f32 = 0.585;
pub var grain_edge: f32 = 0.2;

/// Multitone colours change more slowly than the grain field (measured: neighbouring
/// grain pixels' colours correlate 0.70 one device pixel apart at 2x, 0.37 two apart).
const multitone_colour_scale: f32 = 0.8;

/// A multitone colour channel from a field value: interpolation pulls values toward the
/// middle, so they are pushed back out (Figma's channels spread with sd 52/255).
fn channel(v: f32) f32 {
    return std.math.clamp(0.5 + (v - 0.5) * 1.2, 0, 1);
}

/// How much a grain covers where the field reads `v`.
fn grainCover(v: f32, density: f32) f32 {
    const t = 1 - grain_density_k * std.math.clamp(density, 0, 1);
    return std.math.clamp((v - t) / grain_edge, 0, 1);
}

/// Draws `src` (premultiplied) atop `d`: only where `d` already has content.
fn atop(d: *Rgba, src: Rgba) void {
    const k = 1 - src[3];
    inline for (0..3) |c| d[c] = src[c] * d[3] + d[c] * k;
}

/// Noise: grain over the node's content, in node space (so it scales with the node and
/// repeats from node to node). Measured on Figma's renders: monotone grains take
/// `color` (with its alpha) where a smooth random field is high; duotone puts
/// `secondary` on those grains and `color` where the field is equally low; multitone
/// grains (both tails of an independent field) carry a smoothly varying random colour
/// at `opacity`.
/// Grains are about half the noise size across with soft edges; small exports average
/// the grain over each pixel.
pub fn drawNoise(layer: *Pixmap, e: m.Effect, ctm: Affine) void {
    const inv = ctm.invert() orelse return;
    const cell: Vec2 = .{
        .x = @max(e.grain.x * grain_cell, 0.01),
        .y = @max(e.grain.y * grain_cell, 0.01),
    };
    const ss: u32 = @intFromFloat(std.math.clamp(@ceil(2 / @max(ctm.maxScale(), 0.01)), 1, 4));
    const ssf: f32 = @floatFromInt(ss);
    const inv_n = 1 / (ssf * ssf);
    const w = layer.rect.width();
    const h = layer.rect.height();
    const pc = colour.solid(e.color);
    const sc = colour.solid(e.secondary);
    for (0..h) |y| {
        for (0..w) |x| {
            const d = &layer.data[y * w + x];
            if (d[3] <= 0) continue;
            const dx: f32 = @floatFromInt(layer.rect.x0 + @as(i32, @intCast(x)));
            const dy: f32 = @floatFromInt(layer.rect.y0 + @as(i32, @intCast(y)));
            var hi: f32 = 0;
            var lo: f32 = 0;
            var mc: Rgba = .{ 0, 0, 0, 0 };
            var sy: u32 = 0;
            while (sy < ss) : (sy += 1) {
                var sx: u32 = 0;
                while (sx < ss) : (sx += 1) {
                    const q = inv.apply(.{
                        .x = dx + (@as(f32, @floatFromInt(sx)) + 0.5) / ssf,
                        .y = dy + (@as(f32, @floatFromInt(sy)) + 0.5) / ssf,
                    });
                    const g: Vec2 = .{
                        .x = q.x / cell.x,
                        .y = q.y / cell.y,
                    };
                    switch (e.noise) {
                        .monotone, .duotone => {
                            const v = valueNoise(g, 1);
                            hi += grainCover(v, e.density);
                            if (e.noise == .duotone) lo += grainCover(1 - v, e.density);
                        },
                        .multitone => {
                            const v = valueNoise(g, 2);
                            const c = grainCover(v, e.density) + grainCover(1 - v, e.density);
                            if (c > 0) {
                                const cg = g.scale(multitone_colour_scale);
                                mc[0] += c * channel(valueNoise(cg, 3));
                                mc[1] += c * channel(valueNoise(cg, 4));
                                mc[2] += c * channel(valueNoise(cg, 5));
                                mc[3] += c;
                            }
                        },
                    }
                }
            }
            switch (e.noise) {
                .monotone => if (hi > 0) {
                    const a = pc.a * hi * inv_n;
                    atop(d, .{ pc.r * a, pc.g * a, pc.b * a, a });
                },
                .duotone => {
                    if (hi > 0) {
                        const a = sc.a * hi * inv_n;
                        atop(d, .{ sc.r * a, sc.g * a, sc.b * a, a });
                    }
                    if (lo > 0) {
                        const a = pc.a * lo * inv_n;
                        atop(d, .{ pc.r * a, pc.g * a, pc.b * a, a });
                    }
                },
                .multitone => if (mc[3] > 0) {
                    const o = e.opacity * inv_n;
                    atop(d, .{ mc[0] * o, mc[1] * o, mc[2] * o, mc[3] * o });
                },
            }
        }
    }
}

/// Texture displacement per unit of radius (measured: a radius of 5 moves a straight
/// edge by 1.05 units standard deviation, at most about 3.5).
pub var texture_k: f32 = 0.55;

/// Texture: the node's content displaced by a smooth random field of grain size
/// `grain`, by up to about `radius` × 0.7, which roughens edges into a ragged coast with
/// islands and holes. With `clip` the displaced colours keep the node's own coverage, so
/// a plain fill shows no change (as in Figma's renders).
pub fn drawTexture(gpa: std.mem.Allocator, layer: *Pixmap, e: m.Effect, ctm: Affine) !void {
    const inv = ctm.invert() orelse return;
    const w = layer.rect.width();
    const h = layer.rect.height();
    if (w == 0 or h == 0) return;
    const src = try gpa.dupe(Rgba, layer.data);
    defer gpa.free(src);
    const cell: Vec2 = .{
        .x = @max(e.grain.x * grain_cell, 0.01),
        .y = @max(e.grain.y * grain_cell, 0.01),
    };
    const amp = e.radius * texture_k;
    for (0..h) |y| {
        for (0..w) |x| {
            const cx = @as(f32, @floatFromInt(layer.rect.x0 + @as(i32, @intCast(x)))) + 0.5;
            const cy = @as(f32, @floatFromInt(layer.rect.y0 + @as(i32, @intCast(y)))) + 0.5;
            const q = inv.apply(.{
                .x = cx,
                .y = cy,
            });
            const g: Vec2 = .{
                .x = q.x / cell.x,
                .y = q.y / cell.y,
            };
            const off = ctm.applyVector(.{
                .x = amp * signedNoise(g, 21),
                .y = amp * signedNoise(g, 22),
            });
            var p = bilinear(src, layer.rect, cx + off.x, cy + off.y);
            if (e.clip) {
                // The displaced colour, at the node's own coverage.
                const o = src[y * w + x];
                if (p[3] > 1e-4) {
                    const k = o[3] / p[3];
                    p = .{ p[0] * k, p[1] * k, p[2] * k, o[3] };
                } else p = o;
            }
            layer.data[y * w + x] = p;
        }
    }
}

/// How far (device pixels) an unclipped texture can move content past the node.
pub fn textureRoom(n: *const m.Node, ctm: Affine) f32 {
    var r: f32 = 0;
    for (n.effects) |e| {
        if (e.visible and e.kind == .texture and !e.clip) r = @max(r, e.radius * texture_k * 1.5 * ctm.maxScale() + 2);
    }
    return r;
}

/// Two octaves of value noise, centred on 0 (within -1.5..1.5, near Gaussian).
fn signedNoise(g: Vec2, seed: u32) f32 {
    const a = valueNoise(g, seed) * 2 - 1;
    const b = valueNoise(g.scale(2), seed +% 100) * 2 - 1;
    return a + 0.5 * b;
}

/// `src` (laid out over `rect`) at device point (x, y), bilinear; transparent outside.
fn bilinear(src: []const Rgba, rect: IRect, x: f32, y: f32) Rgba {
    const fx = x - 0.5 - @as(f32, @floatFromInt(rect.x0));
    const fy = y - 0.5 - @as(f32, @floatFromInt(rect.y0));
    const x0f = @floor(fx);
    const y0f = @floor(fy);
    const tx = fx - x0f;
    const ty = fy - y0f;
    const w: i32 = @intCast(rect.width());
    const h: i32 = @intCast(rect.height());
    if (x0f < -2 or y0f < -2 or x0f > @as(f32, @floatFromInt(w)) or y0f > @as(f32, @floatFromInt(h))) return .{ 0, 0, 0, 0 };
    const ix: i32 = @intFromFloat(x0f);
    const iy: i32 = @intFromFloat(y0f);
    var out: Rgba = .{ 0, 0, 0, 0 };
    const taps = [4][3]f32{
        .{ 0, 0, (1 - tx) * (1 - ty) },
        .{ 1, 0, tx * (1 - ty) },
        .{ 0, 1, (1 - tx) * ty },
        .{ 1, 1, tx * ty },
    };
    for (taps) |t| {
        const px = ix + @as(i32, @intFromFloat(t[0]));
        const py = iy + @as(i32, @intFromFloat(t[1]));
        if (px < 0 or py < 0 or px >= w or py >= h or t[2] == 0) continue;
        const p = src[@as(usize, @intCast(py)) * @as(usize, @intCast(w)) + @as(usize, @intCast(px))];
        inline for (0..4) |c| out[c] += p[c] * t[2];
    }
    return out;
}

// Shadow silhouette ----------------------------------------------------------------------

/// Whether a visible paint of the node is see-through by its opacity or colour alpha.
/// Figma casts drop shadows (and knocks them out) as if such paints were opaque: a 20%
/// white card throws the same shadow as a solid one.
pub fn hasTranslucentPaint(n: *const m.Node) bool {
    for ([2][]const m.Paint{ n.fills, n.strokes }) |ps| for (ps) |p| {
        if (!p.visible) continue;
        if (p.opacity < 1 or (p.kind == .solid and colour.solid(p.color).a < 1)) return true;
    };
    return false;
}

/// Copies of `ps` at full opacity (solid colours opaque too).
pub fn opaquePaints(a: std.mem.Allocator, ps: []const m.Paint) ![]m.Paint {
    const out = try a.dupe(m.Paint, ps);
    for (out) |*p| {
        p.opacity = 1;
        if (p.kind == .solid) p.color.a = 1;
    }
    return out;
}

test "progressive ramp runs from start to end and holds beyond" {
    const n: m.Node = .{
        .id = "r",
        .kind = .rectangle,
        .size = .{
            .x = 100,
            .y = 10,
        },
    };
    const e: m.Effect = .{
        .kind = .layer_blur,
        .radius = 10,
        .progressive = .{
            .start = .{
                .y = 0.5,
            },
            .end = .{
                .x = 1,
                .y = 0.5,
            },
        },
    };
    const r = Ramp.init(&n, e, .identity, 1).?;
    try std.testing.expectApproxEqAbs(@as(f32, 0), r.sigma(-5, 3), 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 5), r.sigma(50, 3), 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 10), r.sigma(150, 3), 1e-4);
}

test "noise covers part of the node at half density" {
    var count: u32 = 0;
    var total: f32 = 0;
    var y: f32 = 0;
    while (y < 100) : (y += 1) {
        var x: f32 = 0;
        while (x < 100) : (x += 1) {
            const c = grainCover(valueNoise(.{
                .x = x / 2,
                .y = y / 2,
            }, 1), 0.5);
            total += c;
            count += 1;
        }
    }
    const mean = total / @as(f32, @floatFromInt(count));
    try std.testing.expect(mean > 0.04 and mean < 0.14);
}
