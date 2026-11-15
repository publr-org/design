// Shared by the GPU canvas's pipelines (prepended to paint.wgsl and records.wgsl):
// shapes by formula, paints and blend modes, as the CPU evaluates them. The entry
// files declare the bindings these read (`stops`, `tex`).

struct Shape {
  // kind, next, layer, flags
  head: vec4u,
  inv: vec4f,
  inv_t: vec4f,
  outer: vec4f,
  outer_r: vec4f,
  inner: vec4f,
  inner_r: vec4f,
  pad: vec4f,
}

struct Paint {
  // kind, flags, a, b
  head: vec4u,
  color: vec4f,
  inv: vec4f,
  inv_t: vec4f,
}

const NONE: u32 = 0xffffffffu;

const SHAPE_RECT: u32 = 1u;
const SHAPE_ELLIPSE: u32 = 2u;
const SHAPE_ATLAS: u32 = 3u;

const PAINT_SOLID: u32 = 1u;
const PAINT_LINEAR: u32 = 2u;
const PAINT_RADIAL: u32 = 3u;
const PAINT_ANGULAR: u32 = 4u;
const PAINT_DIAMOND: u32 = 5u;
const PAINT_IMAGE: u32 = 6u;
const PAINT_TEXTURE: u32 = 7u;
const PAINT_SHADOW: u32 = 8u;
const PAINT_SHADOW_FORMULA: u32 = 9u;

const BLEND_LERP: u32 = 31u;
const MASK_ALPHA: u32 = 1u;
const MASK_LUMINANCE: u32 = 2u;
const MASK_INVERSE_ALPHA: u32 = 3u;

const TAU: f32 = 6.28318530717958647;

// Figma's anti-aliasing: the standard 4x pattern at twice the resolution (16 points in a
// pixel, 8 distinct rows and columns), as `mask.figma16`.
const SAMPLES = array<vec2f, 16>(
  vec2f(0.1875, 0.0625), vec2f(0.4375, 0.1875), vec2f(0.0625, 0.3125), vec2f(0.3125, 0.4375),
  vec2f(0.6875, 0.0625), vec2f(0.9375, 0.1875), vec2f(0.5625, 0.3125), vec2f(0.8125, 0.4375),
  vec2f(0.1875, 0.5625), vec2f(0.4375, 0.6875), vec2f(0.0625, 0.8125), vec2f(0.3125, 0.9375),
  vec2f(0.6875, 0.5625), vec2f(0.9375, 0.6875), vec2f(0.5625, 0.8125), vec2f(0.8125, 0.9375),
);

fn apply(s: Shape, p: vec2f) -> vec2f {
  return vec2f(s.inv.x * p.x + s.inv.z * p.y + s.inv_t.x, s.inv.y * p.x + s.inv.w * p.y + s.inv_t.y);
}

// Inside a rectangle with corner radii (tl, tr, br, bl): left and top edges inclusive,
// right and bottom exclusive, as the CPU's crossing test counts.
fn in_rrect(q: vec2f, r: vec4f, rad: vec4f) -> bool {
  if (q.x < r.x || q.x >= r.z || q.y < r.y || q.y >= r.w) {
    return false;
  }
  if (q.x < r.x + rad.x && q.y < r.y + rad.x) {
    let d = q - vec2f(r.x + rad.x, r.y + rad.x);
    return dot(d, d) <= rad.x * rad.x;
  }
  if (q.x > r.z - rad.y && q.y < r.y + rad.y) {
    let d = q - vec2f(r.z - rad.y, r.y + rad.y);
    return dot(d, d) <= rad.y * rad.y;
  }
  if (q.x > r.z - rad.z && q.y > r.w - rad.z) {
    let d = q - vec2f(r.z - rad.z, r.w - rad.z);
    return dot(d, d) <= rad.z * rad.z;
  }
  if (q.x < r.x + rad.w && q.y > r.w - rad.w) {
    let d = q - vec2f(r.x + rad.w, r.w - rad.w);
    return dot(d, d) <= rad.w * rad.w;
  }
  return true;
}

fn in_ellipse(q: vec2f, r: vec4f) -> bool {
  let c = (r.xy + r.zw) * 0.5;
  let h = (r.zw - r.xy) * 0.5;
  let d = (q - c) / h;
  return dot(d, d) <= 1.0;
}

fn in_shape(s: Shape, q: vec2f) -> bool {
  var hit: bool;
  if (s.head.x == SHAPE_ELLIPSE) {
    hit = in_ellipse(q, s.outer);
  } else {
    hit = in_rrect(q, s.outer, s.outer_r);
  }
  // The ring: even-odd of the two edges.
  if ((s.head.w & 1u) != 0u && in_rrect(q, s.inner, s.inner_r)) {
    hit = !hit;
  }
  return hit;
}

// Whether box `b` (x0, y0, x1, y1) lies inside `r` shrunk by `k`.
fn box_within(b: vec4f, r: vec4f, k: f32) -> bool {
  return b.x >= r.x + k && b.y >= r.y + k && b.z < r.z - k && b.w < r.w - k;
}

fn box_apart(b: vec4f, r: vec4f) -> bool {
  return b.z < r.x || b.w < r.y || b.x >= r.z || b.y >= r.w;
}

fn max4(v: vec4f) -> f32 {
  return max(max(v.x, v.y), max(v.z, v.w));
}

// Coverage of a formula shape over pixel `px` (top space): whole or none away from its
// edges, else the share of the 16 samples inside.
fn formula_cov(s: Shape, px: vec2f) -> f32 {
  // The pixel's box in the shape's space.
  let c0 = apply(s, px);
  let c1 = apply(s, px + vec2f(1.0, 0.0));
  let c2 = apply(s, px + vec2f(0.0, 1.0));
  let c3 = apply(s, px + vec2f(1.0, 1.0));
  let b = vec4f(min(min(c0, c1), min(c2, c3)), max(max(c0, c1), max(c2, c3)));
  if (box_apart(b, s.outer)) {
    return 0.0;
  }
  let ring = (s.head.w & 1u) != 0u;
  var solid = false;
  if (s.head.x == SHAPE_ELLIPSE) {
    // Inside the ellipse's inscribed box.
    let c = (s.outer.xy + s.outer.zw) * 0.5;
    let h = (s.outer.zw - s.outer.xy) * 0.5 * 0.7;
    solid = box_within(b, vec4f(c - h, c + h), 0.0);
  } else {
    solid = box_within(b, s.outer, max4(s.outer_r));
  }
  if (solid && (!ring || box_apart(b, s.inner))) {
    return 1.0;
  }
  if (ring && box_within(b, s.inner, max4(s.inner_r)) && !(s.head.x == SHAPE_ELLIPSE)) {
    return 0.0;
  }
  var n = 0u;
  for (var i = 0u; i < 16u; i++) {
    if (in_shape(s, apply(s, px + SAMPLES[i]))) {
      n++;
    }
  }
  return f32(n) / 16.0;
}

// --------------------------------------------------------------------------- paints

fn paint_apply(p: Paint, q: vec2f) -> vec2f {
  return vec2f(p.inv.x * q.x + p.inv.z * q.y + p.inv_t.x, p.inv.y * q.x + p.inv.w * q.y + p.inv_t.y);
}

fn premul(c: vec4f) -> vec4f {
  return vec4f(c.rgb * c.a, c.a);
}

// Stops interpolate straight colour and alpha apart (as `pixmap.sampleStops`).
fn sample_stops(first: u32, count: u32, t: f32) -> vec4f {
  if (count == 0u) {
    return vec4f(0.0);
  }
  if (t <= stops[first].x) {
    return stops[first + 1u];
  }
  for (var i = 1u; i < count; i++) {
    let at = stops[first + i * 2u].x;
    if (t <= at) {
      let a_at = stops[first + (i - 1u) * 2u].x;
      let a = stops[first + (i - 1u) * 2u + 1u];
      let b = stops[first + i * 2u + 1u];
      let span = at - a_at;
      var k = 1.0;
      if (span > 0.0) {
        k = (t - a_at) / span;
      }
      return a + (b - a) * k;
    }
  }
  return stops[first + (count - 1u) * 2u + 1u];
}

fn gradient(p: Paint, q: vec2f) -> vec4f {
  let g = paint_apply(p, q);
  var t = g.x;
  let kind = p.head.x;
  if (kind == PAINT_RADIAL) {
    t = sqrt(g.x * g.x + g.y * g.y);
  } else if (kind == PAINT_ANGULAR) {
    t = atan2(g.y, g.x) / TAU;
    if (t < 0.0) {
      t += 1.0;
    }
  } else if (kind == PAINT_DIAMOND) {
    t = abs(g.x) + abs(g.y);
  }
  return premul(sample_stops(p.head.z, p.head.w, t));
}

// A texel of the image: level 0 holds straight colour, the smaller levels premultiplied
// (as `pixmap.Mipmap`). `level` counts from the engine's level 0; the texture may start
// further down (`base`).
fn image_texel(level: i32, base: i32, x: i32, y: i32, tile: bool) -> vec4f {
  let dim = vec2i(textureDimensions(tex, level - base));
  var xx = x;
  var yy = y;
  if (tile) {
    xx = ((xx % dim.x) + dim.x) % dim.x;
    yy = ((yy % dim.y) + dim.y) % dim.y;
  } else {
    xx = clamp(xx, 0, dim.x - 1);
    yy = clamp(yy, 0, dim.y - 1);
  }
  let t = textureLoad(tex, vec2i(xx, yy), level - base);
  if (level == 0) {
    return premul(t);
  }
  return t;
}

fn image_level(level: i32, base: i32, q0: vec2f, size: vec2f, tile: bool) -> vec4f {
  let dim = vec2f(textureDimensions(tex, level - base));
  let s = dim / size;
  let f = q0 * s - 0.5;
  let f0 = floor(f);
  let t = f - f0;
  let x0 = i32(clamp(f0.x, -1e9, 1e9));
  let y0 = i32(clamp(f0.y, -1e9, 1e9));
  let p00 = image_texel(level, base, x0, y0, tile);
  let p10 = image_texel(level, base, x0 + 1, y0, tile);
  let p01 = image_texel(level, base, x0, y0 + 1, tile);
  let p11 = image_texel(level, base, x0 + 1, y0 + 1, tile);
  let top = p00 + (p10 - p00) * t.x;
  let bot = p01 + (p11 - p01) * t.x;
  return top + (bot - top) * t.y;
}

// The image paint at device point `q`, as `pixmap.ImageShader.eval`.
fn image(p: Paint, q: vec2f) -> vec4f {
  let iq = paint_apply(p, q);
  let size = p.inv_t.zw;
  let tile = (p.head.y & 1u) != 0u;
  if ((p.head.y & 2u) != 0u) {
    if (iq.x < 0.0 || iq.y < 0.0 || iq.x > size.x || iq.y > size.y) {
      return vec4f(0.0);
    }
  }
  let levels = i32(p.head.w);
  let base = levels - i32(textureNumLevels(tex));
  // The device pixel's extent in image pixels; shrunk, an area average.
  let ex = abs(p.inv.x) + abs(p.inv.z);
  let ey = abs(p.inv.y) + abs(p.inv.w);
  if (max(ex, ey) > 1.0) {
    return image_box(levels, base, iq, size, ex, ey, tile);
  }
  return image_level(max(0, base), base, iq, size, tile);
}

// `pixmap.ImageShader.boxAverage`: the average over the ex x ey box (image pixels) at
// `q0`, from the level `boxLevel` picks (never finer than the texture's first).
fn image_box(levels: i32, base: i32, q0: vec2f, size: vec2f, ex: f32, ey: f32, tile: bool) -> vec4f {
  var level = min(i32(max(0.0, floor(log2(max(min(ex, ey) / 4.0, 1.0))))), levels - 1);
  loop {
    if (level + 1 >= levels || max(ex, ey) / exp2(f32(level)) <= 16.0) {
      break;
    }
    level += 1;
  }
  level = max(level, base);
  let dim = vec2f(textureDimensions(tex, level - base));
  let s = dim / size;
  let c = q0 * s;
  let hw = max(0.5, ex * s.x / 2.0);
  let hh = max(0.5, ey * s.y / 2.0);
  let x0 = c.x - hw;
  let x1 = c.x + hw;
  let y0 = c.y - hh;
  let y1 = c.y + hh;
  let ix0 = i32(clamp(floor(x0), -1e9, 1e9));
  let ix1 = i32(clamp(ceil(x1), -1e9, 1e9));
  let iy0 = i32(clamp(floor(y0), -1e9, 1e9));
  let iy1 = i32(clamp(ceil(y1), -1e9, 1e9));
  var acc = vec4f(0.0);
  for (var iy = iy0; iy < iy1; iy++) {
    let fy = f32(iy);
    let wy = min(y1, fy + 1.0) - max(y0, fy);
    if (wy <= 0.0) {
      continue;
    }
    for (var ix = ix0; ix < ix1; ix++) {
      let fx = f32(ix);
      let wx = min(x1, fx + 1.0) - max(x0, fx);
      if (wx <= 0.0) {
        continue;
      }
      acc += image_texel(level, base, ix, iy, tile) * (wx * wy);
    }
  }
  return acc / ((x1 - x0) * (y1 - y0));
}

// A CPU layer: premultiplied texels placed by `inv`; filtered (bilinear) when it stands
// in at another scale.
fn layer_texel(t: texture_2d<f32>, x: i32, y: i32, dim: vec2i) -> vec4f {
  if (x < 0 || y < 0 || x >= dim.x || y >= dim.y) {
    return vec4f(0.0);
  }
  return textureLoad(t, vec2i(x, y), 0);
}

// Texels of `t` bilinear at `f` (texel centres at whole numbers), clear outside.
fn bilinear(t: texture_2d<f32>, f: vec2f) -> vec4f {
  let dim = vec2i(textureDimensions(t, 0));
  let f0 = floor(f);
  let k = f - f0;
  let x0 = i32(clamp(f0.x, -1e8, 1e8));
  let y0 = i32(clamp(f0.y, -1e8, 1e8));
  let top = mix(layer_texel(t, x0, y0, dim), layer_texel(t, x0 + 1, y0, dim), k.x);
  let bot = mix(layer_texel(t, x0, y0 + 1, dim), layer_texel(t, x0 + 1, y0 + 1, dim), k.x);
  return mix(top, bot, k.y);
}

// The error function (Abramowitz and Stegun 7.1.26, within 1.5e-7).
fn erf(x: f32) -> f32 {
  let s = sign(x);
  let a = abs(x);
  let t = 1.0 / (1.0 + 0.3275911 * a);
  let y = 1.0 - (((((1.061405429 * t - 1.453152027) * t) + 1.421413741) * t - 0.284496736) * t + 0.254829592) * t * exp(-a * a);
  return s * y;
}

// The share of a Gaussian of `sigma` below `x`.
fn cdf(x: f32, sigma: f32) -> f32 {
  return 0.5 + 0.5 * erf(x / (sigma * 1.41421356));
}

// The left and right ends of a box with corner radii (tl, tr, br, bl) or of an ellipse at
// height `y`.
fn row_span(b: vec4f, r: vec4f, ellipse: bool, y: f32) -> vec2f {
  if (ellipse) {
    let c = (b.xy + b.zw) * 0.5;
    let h = (b.zw - b.xy) * 0.5;
    let k = (y - c.y) / h.y;
    let w = h.x * sqrt(max(0.0, 1.0 - k * k));
    return vec2f(c.x - w, c.x + w);
  }
  var l = b.x;
  var rr = b.z;
  if (y < b.y + r.x) {
    let d = b.y + r.x - y;
    l = b.x + r.x - sqrt(max(0.0, r.x * r.x - d * d));
  } else if (y > b.w - r.w) {
    let d = y - (b.w - r.w);
    l = b.x + r.w - sqrt(max(0.0, r.w * r.w - d * d));
  }
  if (y < b.y + r.y) {
    let d = b.y + r.y - y;
    rr = b.z - r.y + sqrt(max(0.0, r.y * r.y - d * d));
  } else if (y > b.w - r.z) {
    let d = y - (b.w - r.z);
    rr = b.z - r.z + sqrt(max(0.0, r.z * r.z - d * d));
  }
  return vec2f(l, rr);
}

// A box (or an ellipse) with corners blurred by a Gaussian, at `q`: exact for a plain box
// (the product of two edge integrals); otherwise each row's exact integral, summed over the
// Gaussian across rows.
fn blurred_shape(p: Paint, q: vec2f) -> f32 {
  let b = p.inv;
  let r = p.inv_t;
  let sigma = max(bitcast<f32>(p.head.w), 0.25);
  let ellipse = (p.head.y & 1u) != 0u;
  if (b.z <= b.x || b.w <= b.y) {
    return 0.0;
  }
  if (!ellipse && max(max(r.x, r.y), max(r.z, r.w)) <= 0.0) {
    let x = cdf(b.z - q.x, sigma) - cdf(b.x - q.x, sigma);
    let y = cdf(b.w - q.y, sigma) - cdf(b.y - q.y, sigma);
    return x * y;
  }
  let lo = max(b.y, q.y - 4.0 * sigma);
  let hi = min(b.w, q.y + 4.0 * sigma);
  if (hi <= lo) {
    return 0.0;
  }
  let n = 48u;
  let step = (hi - lo) / f32(n);
  var acc = 0.0;
  for (var i = 0u; i < n; i++) {
    let y = lo + (f32(i) + 0.5) * step;
    let s = row_span(b, r, ellipse, y);
    let dy = (y - q.y) / sigma;
    acc += exp(-0.5 * dy * dy) * (cdf(s.y - q.x, sigma) - cdf(s.x - q.x, sigma));
  }
  return acc * step / (sigma * 2.50662827);
}

// --------------------------------------------------------------------------- blending

fn hard_light(cb: f32, cs: f32) -> f32 {
  if (cs <= 0.5) {
    return cb * 2.0 * cs;
  }
  let t = 2.0 * cs - 1.0;
  return cb + t - cb * t;
}

// `pixmap.separable`: `cb` backdrop, `cs` source, straight. Modes in `pix.BlendMode`'s
// order.
fn separable(mode: u32, cb: f32, cs: f32) -> f32 {
  switch (mode) {
    case 1u: {
      return cb * cs;
    }
    case 2u: {
      return cb + cs - cb * cs;
    }
    case 3u: {
      return hard_light(cs, cb);
    }
    case 4u: {
      return min(cb, cs);
    }
    case 5u: {
      return max(cb, cs);
    }
    case 6u: {
      if (cb <= 0.0) {
        return 0.0;
      }
      if (cs >= 1.0) {
        return 1.0;
      }
      return min(1.0, cb / (1.0 - cs));
    }
    case 7u: {
      if (cb >= 1.0) {
        return 1.0;
      }
      if (cs <= 0.0) {
        return 0.0;
      }
      return 1.0 - min(1.0, (1.0 - cb) / cs);
    }
    case 8u: {
      return min(1.0, cb + cs);
    }
    case 9u: {
      return max(0.0, cb + cs - 1.0);
    }
    case 10u: {
      return hard_light(cb, cs);
    }
    case 11u: {
      // Figma's soft light: the W3C formula with its two branches swapped (measured).
      if (cs <= 0.5) {
        var dd = sqrt(cb);
        if (cb <= 0.25) {
          dd = ((16.0 * cb - 12.0) * cb + 4.0) * cb;
        }
        return cb + (2.0 * cs - 1.0) * (dd - cb);
      }
      return cb + (2.0 * cs - 1.0) * (cb - cb * cb);
    }
    case 12u: {
      return abs(cb - cs);
    }
    case 13u: {
      return cb + cs - 2.0 * cb * cs;
    }
    default: {
      return cs;
    }
  }
}

fn lum(c: vec3f) -> f32 {
  return 0.3 * c.r + 0.59 * c.g + 0.11 * c.b;
}

fn clip_color(c: vec3f) -> vec3f {
  let l = lum(c);
  let n = min(c.r, min(c.g, c.b));
  let x = max(c.r, max(c.g, c.b));
  var o = c;
  if (n < 0.0) {
    o = l + (o - l) * l / (l - n);
  }
  if (x > 1.0) {
    o = l + (o - l) * (1.0 - l) / (x - l);
  }
  return o;
}

fn set_lum(c: vec3f, l: f32) -> vec3f {
  return clip_color(c + (l - lum(c)));
}

fn sat(c: vec3f) -> f32 {
  return max(c.r, max(c.g, c.b)) - min(c.r, min(c.g, c.b));
}

fn set_sat_ch(x: f32, mx: f32, mn: f32, s: f32) -> f32 {
  if (x == mx) {
    return s;
  }
  if (x == mn) {
    return 0.0;
  }
  return (x - mn) * s / (mx - mn);
}

fn set_sat(c: vec3f, s: f32) -> vec3f {
  let mx = max(c.r, max(c.g, c.b));
  let mn = min(c.r, min(c.g, c.b));
  if (mx <= mn) {
    return vec3f(0.0);
  }
  return vec3f(set_sat_ch(c.r, mx, mn, s), set_sat_ch(c.g, mx, mn, s), set_sat_ch(c.b, mx, mn, s));
}

// `pixmap.blendPixel`: premultiplied `s0` at coverage `c` onto `d`, by the W3C model.
fn blend_pixel(d: vec4f, s0: vec4f, c: f32, mode: u32) -> vec4f {
  let s = s0 * c;
  let sa = s.a;
  let da = d.a;
  if (sa <= 0.0) {
    return d;
  }
  if (mode == 8u || mode == 9u) {
    // Plus-lighter and plus-darker on premultiplied colour.
    let ra = min(1.0, sa + da);
    if (mode == 8u) {
      return vec4f(min(vec3f(ra), d.rgb + s.rgb), ra);
    }
    return vec4f(max(vec3f(0.0), ra - ((da - d.rgb) + (sa - s.rgb))), ra);
  }
  let cs = s.rgb / sa;
  var cb = vec3f(0.0);
  if (da > 0.0) {
    cb = d.rgb / da;
  }
  var b: vec3f;
  switch (mode) {
    case 14u: {
      b = set_lum(set_sat(cs, sat(cb)), lum(cb));
    }
    case 15u: {
      b = set_lum(set_sat(cb, sat(cs)), lum(cb));
    }
    case 16u: {
      b = set_lum(cs, lum(cb));
    }
    case 17u: {
      b = set_lum(cb, lum(cs));
    }
    default: {
      b = vec3f(separable(mode, cb.r, cs.r), separable(mode, cb.g, cs.g), separable(mode, cb.b, cs.b));
    }
  }
  let ra = sa + da - sa * da;
  return vec4f(s.rgb * (1.0 - da) + d.rgb * (1.0 - sa) + sa * da * clamp(b, vec3f(0.0), vec3f(1.0)), ra);
}

