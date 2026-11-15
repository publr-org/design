// Coverage of paths and glyphs from their curves, at any scale, as the CPU computes it
// (`mask.fillSampled` over `Path.flatten`): each curve is taken to device space, flattened
// by Wang's formula with the CPU's tolerance (the same points), and the winding at Figma's
// 16 sample points of the pixel counts the segments a sample's row crosses at or left of
// it, each spanning [min y, max y) of its ends. Lines and the closing line of each contour
// are curves of their own (p1 NaN). The entry file declares `curves` and `geo` (paths,
// then their bands, then the bands' curves, as u32 words at `frame.bands_off` and
// `frame.items_off`).

struct PathRec {
  // curve_first, curve_count, band_first, band_count
  head: vec4u,
  // y0, y1 (the bands' range, the path's units), unused, unused
  yr: vec4f,
  // Its coverage mask (`masks` in records.wgsl; NONE: none).
  mask: u32,
}

fn path_rec(pi: u32) -> PathRec {
  let o = pi * 8u;
  return PathRec(vec4u(geo[o], geo[o + 1u], geo[o + 2u], geo[o + 3u]), vec4f(bitcast<f32>(geo[o + 4u]), bitcast<f32>(geo[o + 5u]), 0.0, 0.0), geo[o + 6u]);
}


// x' = m.x x + m.z y + t.x, y' = m.y x + m.w y + t.y (`geom.Affine`).
struct Aff {
  m: vec4f,
  t: vec2f,
}

fn aff_apply(a: Aff, p: vec2f) -> vec2f {
  return vec2f(a.m.x * p.x + a.m.z * p.y + a.t.x, a.m.y * p.x + a.m.w * p.y + a.t.y);
}

// `s` after `i`, as `Affine.mul`.
fn aff_mul(s: Aff, i: Aff) -> Aff {
  return Aff(
    vec4f(s.m.x * i.m.x + s.m.z * i.m.y, s.m.y * i.m.x + s.m.w * i.m.y, s.m.x * i.m.z + s.m.z * i.m.w, s.m.y * i.m.z + s.m.w * i.m.w),
    vec2f(s.m.x * i.t.x + s.m.z * i.t.y + s.t.x, s.m.y * i.t.x + s.m.w * i.t.y + s.t.y),
  );
}

fn aff_invert(a: Aff) -> Aff {
  let dt = a.m.x * a.m.w - a.m.y * a.m.z;
  if (abs(dt) < 1e-12) {
    return Aff(vec4f(0.0), vec2f(0.0));
  }
  let id = 1.0 / dt;
  return Aff(vec4f(a.m.w * id, -a.m.y * id, -a.m.z * id, a.m.x * id), vec2f((a.m.z * a.t.y - a.m.w * a.t.x) * id, (a.m.y * a.t.x - a.m.x * a.t.y) * id));
}

fn aff_max_scale(a: Aff) -> f32 {
  return max(sqrt(a.m.x * a.m.x + a.m.y * a.m.y), sqrt(a.m.z * a.m.z + a.m.w * a.m.w));
}

// The first and last sample rows of a pixel, from its top.
const ROW_LO: f32 = 0.0625;
const ROW_HI: f32 = 0.9375;

// Winding numbers at the 16 sample points: `a` and `b` the two samples of rows 0-3,
// `c` and `d` those of rows 4-7 (`SAMPLES` in common.wgsl: rows of y 1/16 .. 15/16 in
// eighths, two samples each).
struct Wind {
  a: vec4i,
  b: vec4i,
  c: vec4i,
  d: vec4i,
}

const ROWS_TOP = vec4f(0.0625, 0.1875, 0.3125, 0.4375);
const ROWS_BOT = vec4f(0.5625, 0.6875, 0.8125, 0.9375);
// Each row's two sample x (the same in both halves).
const XS_A = vec4f(0.1875, 0.4375, 0.0625, 0.3125);
const XS_B = vec4f(0.6875, 0.9375, 0.5625, 0.8125);

// Segment a->b's crossings at the pixel's samples (`px` its top left), into `w`.
fn seg_wind(a: vec2f, b: vec2f, px: vec2f, w: ptr<function, Wind>) {
  if (a.y == b.y) {
    return;
  }
  let lo = min(a.y, b.y);
  let hi = max(a.y, b.y);
  if (hi <= px.y + ROW_LO || lo > px.y + ROW_HI) {
    return;
  }
  if (min(a.x, b.x) > px.x + ROW_HI) {
    return;
  }
  var dir = -1;
  if (b.y > a.y) {
    dir = 1;
  }
  let d4 = vec4i(dir);
  let z4 = vec4i(0);
  let left = max(a.x, b.x) < px.x + ROW_LO;
  let sy0 = px.y + ROWS_TOP;
  let sy1 = px.y + ROWS_BOT;
  let in0 = (sy0 >= vec4f(lo)) & (sy0 < vec4f(hi));
  let in1 = (sy1 >= vec4f(lo)) & (sy1 < vec4f(hi));
  if (left) {
    (*w).a += select(z4, d4, in0);
    (*w).b += select(z4, d4, in0);
    (*w).c += select(z4, d4, in1);
    (*w).d += select(z4, d4, in1);
    return;
  }
  let dy = b.y - a.y;
  let dx = b.x - a.x;
  let x0 = a.x + dx * ((sy0 - a.y) / dy);
  let x1 = a.x + dx * ((sy1 - a.y) / dy);
  let sa = px.x + XS_A;
  let sb = px.x + XS_B;
  (*w).a += select(z4, d4, in0 & (sa >= x0));
  (*w).b += select(z4, d4, in0 & (sb >= x0));
  (*w).c += select(z4, d4, in1 & (sa >= x1));
  (*w).d += select(z4, d4, in1 & (sb >= x1));
}

// A line's p1 is a NaN (its bits compared: GPU compilers may assume floats are never NaN).
fn is_line(c: CurveRec) -> bool {
  return (bitcast<u32>(c.p.z) & 0x7f800000u) == 0x7f800000u;
}

fn cubic_at(p0: vec2f, p1: vec2f, p2: vec2f, p3: vec2f, t: f32) -> vec2f {
  let u = 1.0 - t;
  let a = u * u * u;
  let b = 3.0 * u * u * t;
  let c = 3.0 * u * t * t;
  let d = t * t * t;
  return vec2f(a * p0.x + b * p1.x + c * p2.x + d * p3.x, a * p0.y + b * p1.y + c * p2.y + d * p3.y);
}

fn len2(v: vec2f) -> f32 {
  return sqrt(v.x * v.x + v.y * v.y);
}

// How many segments the CPU flattens a device-space cubic into (`Path.flatten`).
fn wang(p0: vec2f, p1: vec2f, p2: vec2f, p3: vec2f) -> u32 {
  let dd1 = (p0 - p1 * 2.0) + p2;
  let dd2 = (p1 - p2 * 2.0) + p3;
  let mm = max(len2(dd1), len2(dd2));
  let nf = ceil(sqrt(0.75 * mm / 0.05));
  return u32(min(max(nf, 1.0), 512.0));
}

// One device-space curve's crossings at the pixel's samples.
fn curve_wind(p0: vec2f, p1: vec2f, p2: vec2f, p3: vec2f, line: bool, px: vec2f, w: ptr<function, Wind>) {
  if (line) {
    seg_wind(p0, p3, px, w);
    return;
  }
  let ymin = min(min(p0.y, p1.y), min(p2.y, p3.y));
  let ymax = max(max(p0.y, p1.y), max(p2.y, p3.y));
  if (ymax <= px.y + ROW_LO || ymin > px.y + ROW_HI) {
    return;
  }
  let xmin = min(min(p0.x, p1.x), min(p2.x, p3.x));
  if (xmin > px.x + ROW_HI) {
    return;
  }
  let xmax = max(max(p0.x, p1.x), max(p2.x, p3.x));
  // Wholly left of the samples and monotone in y: every segment's crossing counts, and
  // the segments' spans join to the ends' span.
  let up = p0.y <= p1.y && p1.y <= p2.y && p2.y <= p3.y;
  let down = p0.y >= p1.y && p1.y >= p2.y && p2.y >= p3.y;
  if (xmax < px.x + ROW_LO && (up || down)) {
    seg_wind(p0, p3, px, w);
    return;
  }
  let n = wang(p0, p1, p2, p3);
  let fn_ = f32(n);
  var a = p0;
  if (n <= 24u || !(up || down)) {
    for (var i = 1u; i <= n; i++) {
      let b = cubic_at(p0, p1, p2, p3, f32(i) / fn_);
      seg_wind(a, b, px, w);
      a = b;
    }
    return;
  }
  // Many segments of a curve monotone in y: only those spanning the pixel's rows matter.
  // The vertices' y are monotone: find the last vertex at or before the first row.
  let y_lo = px.y + ROW_LO;
  let y_hi = px.y + ROW_HI;
  var lo_i = 0u;
  var hi_i = n;
  // Invariant: the vertex at lo_i is on the near side of y_lo.
  loop {
    if (hi_i - lo_i <= 1u) {
      break;
    }
    let mid = (lo_i + hi_i) / 2u;
    let v = cubic_at(p0, p1, p2, p3, f32(mid) / fn_);
    if ((up && v.y <= y_lo) || (down && v.y >= y_hi)) {
      lo_i = mid;
    } else {
      hi_i = mid;
    }
  }
  var i = lo_i;
  if (i > 0u) {
    i -= 1u;
  }
  a = cubic_at(p0, p1, p2, p3, f32(i) / fn_);
  if (i == 0u) {
    a = p0;
  }
  loop {
    if (i >= n) {
      break;
    }
    let b = cubic_at(p0, p1, p2, p3, f32(i + 1u) / fn_);
    seg_wind(a, b, px, w);
    // Past the rows: done.
    if ((up && min(a.y, b.y) > y_hi) || (down && max(a.y, b.y) < y_lo)) {
      break;
    }
    a = b;
    i++;
  }
}

fn wind_in(v: vec4i, evenodd: bool) -> vec4f {
  if (evenodd) {
    return select(vec4f(0.0), vec4f(1.0), (v & vec4i(1)) != vec4i(0));
  }
  return select(vec4f(0.0), vec4f(1.0), v != vec4i(0));
}

fn wind_cov(w: ptr<function, Wind>, evenodd: bool) -> f32 {
  let n = wind_in((*w).a, evenodd) + wind_in((*w).b, evenodd) + wind_in((*w).c, evenodd) + wind_in((*w).d, evenodd);
  return dot(n, vec4f(1.0)) / 16.0;
}

// Curve `ci` (its units) through `inner` then `outer` (two steps, as the CPU maps a
// glyph's outline to node space and then to device space; `two` false: `outer` only).
fn curve_dev(ci: u32, inner: Aff, outer: Aff, two: bool, px: vec2f, w: ptr<function, Wind>) {
  let c = curves[ci];
  let line = is_line(c);
  var p0 = c.p.xy;
  var p1 = c.p.zw;
  var p2 = c.q.xy;
  var p3 = c.q.zw;
  if (two) {
    p0 = aff_apply(inner, p0);
    p3 = aff_apply(inner, p3);
    if (!line) {
      p1 = aff_apply(inner, p1);
      p2 = aff_apply(inner, p2);
    }
  }
  p0 = aff_apply(outer, p0);
  p3 = aff_apply(outer, p3);
  if (!line) {
    p1 = aff_apply(outer, p1);
    p2 = aff_apply(outer, p2);
  }
  curve_wind(p0, p1, p2, p3, line, px, w);
}

// Coverage of path `pi` at pixel `px` (top space): its curves through `inner` (when
// `two`) and `outer` to device space.
fn path_cov(pi: u32, inner: Aff, outer: Aff, two: bool, px: vec2f, evenodd: bool) -> f32 {
  let pr = path_rec(pi);
  // Drawn no larger than its mask: the mask's area average.
  if (pr.mask != NONE) {
    var full = outer;
    if (two) {
      full = aff_mul(outer, inner);
    }
    let m = mask_rec(pr.mask);
    if (aff_max_scale(full) <= m.k) {
      return mask_cov(m, full, px);
    }
  }
  return path_cov_curves(pi, inner, outer, two, px, evenodd);
}

// `path_cov` from the curves alone.
fn path_cov_curves(pi: u32, inner: Aff, outer: Aff, two: bool, px: vec2f, evenodd: bool) -> f32 {
  let pr = path_rec(pi);
  var w = Wind(vec4i(0), vec4i(0), vec4i(0), vec4i(0));
  var full = outer;
  if (two) {
    full = aff_mul(outer, inner);
  }
  let nb = pr.head.w;
  // Upright: a device row is a row of the path, so only its bands' curves are read.
  if (nb > 1u && full.m.y == 0.0 && full.m.z == 0.0 && full.m.w != 0.0) {
    let span = pr.yr.y - pr.yr.x;
    let fb = f32(nb);
    let ya = (px.y + ROW_LO - full.t.y) / full.m.w;
    let yb = (px.y + ROW_HI - full.t.y) / full.m.w;
    let k0 = u32(clamp(floor((min(ya, yb) - pr.yr.x) / span * fb), 0.0, fb - 1.0));
    let k1 = u32(clamp(floor((max(ya, yb) - pr.yr.x) / span * fb), 0.0, fb - 1.0));
    for (var k = k0; k <= k1; k++) {
      let bo = frame.bands_off + (pr.head.z + k) * 2u;
      let band = vec2u(geo[bo], geo[bo + 1u]);
      for (var j = 0u; j < band.y; j++) {
        let ci = geo[frame.items_off + band.x + j];
        if (k > k0) {
          // A curve in several bands is read in the first of them the pixel reads.
          let c = curves[ci];
          var cy = min(c.p.y, c.q.w);
          if (!is_line(c)) {
            cy = min(cy, min(c.p.w, c.q.y));
          }
          let first = u32(clamp(floor((cy - pr.yr.x) / span * fb), 0.0, fb - 1.0));
          if (max(first, k0) != k) {
            continue;
          }
        }
        curve_dev(ci, inner, outer, two, px, &w);
      }
    }
    return wind_cov(&w, evenodd);
  }
  for (var j = 0u; j < pr.head.y; j++) {
    curve_dev(pr.head.x + j, inner, outer, two, px, &w);
  }
  return wind_cov(&w, evenodd);
}
