//! How a paint's colour becomes what is composited. Pubd keeps colours as authored, at full
//! precision; quantising them to bytes is this renderer's decision, made here alone.
//!
//! Figma quantises colours to 8 bits before compositing, and not all the same way
//! (measured on the corpora): a solid colour rounds exactly, so its lavender g = 0.7
//! (0.69999999 in f32, 178.49999 in f64) is 178, which colour burn shows when it reads the
//! colour as the backdrop; a gradient stop rounds like an f32 product, where 0.7 × 255 is
//! exactly 178.5 and rounds up to 179, which lighten over the stop shows. Solids, strokes,
//! frame backgrounds and effect colours (shadows, noise) take the first rule, gradient stops
//! the second.

const std = @import("std");
const m = @import("../pubd/model.zig");

/// Quantise colours to 8 bits as Figma does; off, colours composite at full precision.
pub var quantise = true;

/// A solid paint, stroke, background or effect colour: each channel to the nearest byte of
/// `c × 255` computed exactly (in f64).
pub fn solid(c: m.Color) m.Color {
    if (!quantise) return c;
    return .{
        .r = exact(c.r),
        .g = exact(c.g),
        .b = exact(c.b),
        .a = exact(c.a),
    };
}

/// A gradient stop: each channel to the nearest byte of the f32 product `c × 255`.
pub fn stop(c: m.Color) m.Color {
    if (!quantise) return c;
    return .{
        .r = product(c.r),
        .g = product(c.g),
        .b = product(c.b),
        .a = product(c.a),
    };
}

fn exact(v: f32) f32 {
    const c = std.math.clamp(v, 0, 1);
    return byte(@round(@as(f64, c) * 255));
}

fn product(v: f32) f32 {
    const c = std.math.clamp(v, 0, 1);
    return byte(@round(c * 255));
}

/// The byte `n` as a channel, `n / 255` divided in f32 as a hex colour reads.
fn byte(n: anytype) f32 {
    const k: u8 = @intFromFloat(n);
    return @as(f32, @floatFromInt(k)) / 255;
}

test "colours quantise as Figma does" {
    // 0.7 is 0.69999999 in f32: 178.49999 in f64, exactly 178.5 if multiplied in f32.
    const c: m.Color = .{
        .r = 0.76,
        .g = 0.7,
        .b = 0.94,
    };
    try std.testing.expectEqual(@as(f32, 178.0 / 255.0), solid(c).g);
    try std.testing.expectEqual(@as(f32, 179.0 / 255.0), stop(c).g);
    try std.testing.expectEqual(@as(f32, 194.0 / 255.0), solid(c).r);
    try std.testing.expectEqual(@as(f32, 1), solid(c).a);
    quantise = false;
    defer quantise = true;
    try std.testing.expectEqual(@as(f32, 0.7), stop(c).g);
}
