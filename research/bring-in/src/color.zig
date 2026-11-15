//! Colour distances: sRGB to CIELAB (D65) and CIEDE2000. A ΔE00 under 1 is not
//! visible; under 2 only side by side; 3 and more is a different colour to most eyes.

const std = @import("std");

pub const Lab = struct {
    l: f64,
    a: f64,
    b: f64,
};

fn linear(c: f64) f64 {
    return if (c <= 0.04045) c / 12.92 else std.math.pow(f64, (c + 0.055) / 1.055, 2.4);
}

fn f(t: f64) f64 {
    const d = 6.0 / 29.0;
    return if (t > d * d * d) std.math.cbrt(t) else t / (3 * d * d) + 4.0 / 29.0;
}

/// sRGB channels 0..1 to CIELAB under D65.
pub fn lab(r: f64, g: f64, b: f64) Lab {
    const R = linear(r);
    const G = linear(g);
    const B = linear(b);
    const x = (0.4124564 * R + 0.3575761 * G + 0.1804375 * B) / 0.95047;
    const y = 0.2126729 * R + 0.7151522 * G + 0.0721750 * B;
    const z = (0.0193339 * R + 0.1191920 * G + 0.9503041 * B) / 1.08883;
    return .{
        .l = 116 * f(y) - 16,
        .a = 500 * (f(x) - f(y)),
        .b = 200 * (f(y) - f(z)),
    };
}

pub fn labHex(rgb: u32) Lab {
    return lab(@as(f64, @floatFromInt((rgb >> 16) & 255)) / 255, @as(f64, @floatFromInt((rgb >> 8) & 255)) / 255, @as(f64, @floatFromInt(rgb & 255)) / 255);
}

fn deg(x: f64) f64 {
    return x * 180 / std.math.pi;
}

fn rad(x: f64) f64 {
    return x * std.math.pi / 180;
}

/// CIEDE2000 colour difference.
pub fn de2000(p: Lab, q: Lab) f64 {
    const c1 = @sqrt(p.a * p.a + p.b * p.b);
    const c2 = @sqrt(q.a * q.a + q.b * q.b);
    const cm = (c1 + c2) / 2;
    const cm7 = std.math.pow(f64, cm, 7);
    const g = 0.5 * (1 - @sqrt(cm7 / (cm7 + std.math.pow(f64, 25, 7))));
    const a1 = (1 + g) * p.a;
    const a2 = (1 + g) * q.a;
    const c1p = @sqrt(a1 * a1 + p.b * p.b);
    const c2p = @sqrt(a2 * a2 + q.b * q.b);
    var h1 = if (a1 == 0 and p.b == 0) 0 else deg(std.math.atan2(p.b, a1));
    if (h1 < 0) h1 += 360;
    var h2 = if (a2 == 0 and q.b == 0) 0 else deg(std.math.atan2(q.b, a2));
    if (h2 < 0) h2 += 360;
    const dl = q.l - p.l;
    const dc = c2p - c1p;
    var dh: f64 = 0;
    if (c1p * c2p != 0) {
        dh = h2 - h1;
        if (dh > 180) dh -= 360 else if (dh < -180) dh += 360;
    }
    const dH = 2 * @sqrt(c1p * c2p) * @sin(rad(dh / 2));
    const lm = (p.l + q.l) / 2;
    const cpm = (c1p + c2p) / 2;
    var hm = h1 + h2;
    if (c1p * c2p != 0) {
        if (@abs(h1 - h2) > 180) hm = if (h1 + h2 < 360) hm + 360 else hm - 360;
        hm /= 2;
    }
    const t = 1 - 0.17 * @cos(rad(hm - 30)) + 0.24 * @cos(rad(2 * hm)) + 0.32 * @cos(rad(3 * hm + 6)) - 0.20 * @cos(rad(4 * hm - 63));
    const dtheta = 30 * @exp(-std.math.pow(f64, (hm - 275) / 25, 2));
    const cpm7 = std.math.pow(f64, cpm, 7);
    const rc = 2 * @sqrt(cpm7 / (cpm7 + std.math.pow(f64, 25, 7)));
    const lm50 = (lm - 50) * (lm - 50);
    const sl = 1 + 0.015 * lm50 / @sqrt(20 + lm50);
    const sc = 1 + 0.045 * cpm;
    const sh = 1 + 0.015 * cpm * t;
    const rt = -@sin(rad(2 * dtheta)) * rc;
    const x = dl / sl;
    const y = dc / sc;
    const z = dH / sh;
    return @sqrt(x * x + y * y + z * z + rt * y * z);
}

test "ciede2000 reference pairs (Sharma et al.)" {
    const pairs = [_][7]f64{
        .{ 50, 2.6772, -79.7751, 50, 0, -82.7485, 2.0425 },
        .{ 50, 2.5, 0, 50, 0, -2.5, 4.3065 },
        .{ 50, 2.5, 0, 73, 25, -18, 27.1492 },
        .{ 60.2574, -34.0099, 36.2677, 60.4626, -34.1751, 39.4387, 1.2644 },
    };
    for (pairs) |pr| {
        const d = de2000(.{
            .l = pr[0],
            .a = pr[1],
            .b = pr[2],
        }, .{
            .l = pr[3],
            .a = pr[4],
            .b = pr[5],
        });
        try std.testing.expectApproxEqAbs(pr[6], d, 1e-3);
    }
}
