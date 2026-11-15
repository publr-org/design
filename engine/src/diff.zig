//! Comparing a render against a reference, pixel by pixel.

const std = @import("std");
const IRect = @import("raster/mask.zig").IRect;

pub const Result = struct {
    pixels: u64,
    /// Mean of each pixel's largest channel difference, 0..255.
    mean: f64,
    within2: u64,
    within16: u64,
    non_text_pixels: u64,
    non_text_within2: u64,
    /// Within 2/255, except inside images where within 16/255 counts: what the eye sees.
    visual: u64,
    /// RGBA8 picture of the differences: grey reference, red where they differ.
    heat: []u8,
};

/// Compares two straight-alpha RGBA8 images of `w` x `h`, premultiplied first so fully
/// transparent pixels compare equal whatever their colour. `text` lists areas left out of
/// the non-text figures.
pub fn compare(gpa: std.mem.Allocator, ours: []const u8, ref: []const u8, w: u32, h: u32, text: []const IRect, images: []const IRect) !Result {
    const heat = try gpa.alloc(u8, w * h * 4);
    var res: Result = .{
        .pixels = 0,
        .mean = 0,
        .within2 = 0,
        .within16 = 0,
        .non_text_pixels = 0,
        .non_text_within2 = 0,
        .visual = 0,
        .heat = heat,
    };
    var sum: f64 = 0;
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            const i = (y * w + x) * 4;
            const a = premul(ours[i..][0..4].*);
            const b = premul(ref[i..][0..4].*);
            var d: u8 = 0;
            for (a, b) |p, q| d = @max(d, if (p > q) p - q else q - p);
            res.pixels += 1;
            sum += @floatFromInt(d);
            if (d <= 2) res.within2 += 1;
            if (d <= 16) res.within16 += 1;
            if (d <= 2 or (d <= 16 and inAny(images, @intCast(x), @intCast(y)))) res.visual += 1;
            if (!inAny(text, @intCast(x), @intCast(y))) {
                res.non_text_pixels += 1;
                if (d <= 2) res.non_text_within2 += 1;
            }
            const grey: u8 = @intCast((@as(u32, b[0]) + b[1] + b[2]) / 3 / 3 + 170 * (255 - @as(u32, b[3])) / 255);
            if (d <= 2) {
                heat[i..][0..4].* = .{ grey, grey, grey, 255 };
            } else {
                const k: u8 = @intCast(@min(255, 96 + @as(u32, d) * 3));
                heat[i..][0..4].* = .{ k, 0, if (d <= 16) 0 else k / 2, 255 };
            }
        }
    }
    res.mean = sum / @as(f64, @floatFromInt(@max(res.pixels, 1)));
    return res;
}

fn premul(p: [4]u8) [4]u8 {
    const a: u32 = p[3];
    return .{
        @intCast((@as(u32, p[0]) * a + 127) / 255),
        @intCast((@as(u32, p[1]) * a + 127) / 255),
        @intCast((@as(u32, p[2]) * a + 127) / 255),
        p[3],
    };
}

fn inAny(rects: []const IRect, x: i32, y: i32) bool {
    for (rects) |r| {
        if (x >= r.x0 - 2 and x < r.x1 + 2 and y >= r.y0 - 2 and y < r.y1 + 2) return true;
    }
    return false;
}
