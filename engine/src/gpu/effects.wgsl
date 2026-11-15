// Effect passes on the GPU canvas's surfaces, with the CPU renderer's numbers: the same
// kernels (Figma's Gaussian cut at the blur radius, three sigmas for shadows, three boxes
// past sigma 24), the same morphology for spread, the same seeded grain and displacement
// (`render/effects.zig`, `raster/pixmap.zig`). Each dispatch reads `src` and writes `dst`;
// separable passes run rows, then columns, through a second texture.

struct Params {
  // kind, direction (0 rows, 1 columns), step, unused
  head: vec4u,
  // dst width, height, its x0, y0 (the space its pixels are in)
  size: vec4i,
  i0: vec4i,
  i1: vec4i,
  f0: vec4f,
  f1: vec4f,
  f2: vec4f,
  f3: vec4f,
  f4: vec4f,
}

@group(0) @binding(0) var<uniform> P: Params;
@group(0) @binding(1) var src: texture_2d<f32>;
@group(0) @binding(2) var dst: texture_storage_2d<rgba16float, write>;

// `src`'s texel, clear outside `dim` (textures may be larger than what they hold).
fn load_in(p: vec2i, dim: vec2i) -> vec4f {
  if (p.x < 0 || p.y < 0 || p.x >= dim.x || p.y >= dim.y) {
    return vec4f(0.0);
  }
  return textureLoad(src, p, 0);
}

// A texel of a source the size of `dst`.
fn load(p: vec2i) -> vec4f {
  return load_in(p, P.size.xy);
}

fn axis() -> vec2i {
  if (P.head.y == 0u) {
    return vec2i(1, 0);
  }
  return vec2i(0, 1);
}

fn inside(p: vec2i) -> bool {
  return p.x < P.size.x && p.y < P.size.y;
}

// Gathers along the pass's axis with a Gaussian of `sigma` cut at `r` texels, normalised
// over the whole kernel; outside reads clear.
fn gather(p: vec2i, sigma: f32, r: i32) -> vec4f {
  if (r <= 0) {
    return load(p);
  }
  let a = axis();
  var acc = vec4f(0.0);
  var sum = 0.0;
  let k = -1.0 / (2.0 * sigma * sigma);
  for (var i = -r; i <= r; i++) {
    let d = f32(i);
    let w = exp(d * d * k);
    sum += w;
    acc += load(p + a * i) * w;
  }
  return acc / sum;
}

// --------------------------------------------------------------------------- blurs

@compute @workgroup_size(8, 8)
fn gauss(@builtin(global_invocation_id) id: vec3u) {
  let p = vec2i(id.xy);
  if (!inside(p)) {
    return;
  }
  textureStore(dst, p, gather(p, P.f0.x, P.i0.x));
}

// One box of half width `r` along each line (one invocation per line), as
// `pixmap.boxLine`: a running sum, clear past the ends.
@compute @workgroup_size(64)
fn box(@builtin(global_invocation_id) id: vec3u) {
  let line = i32(id.x);
  let along_rows = P.head.y == 0u;
  var n = P.size.x;
  var lines = P.size.y;
  if (!along_rows) {
    n = P.size.y;
    lines = P.size.x;
  }
  if (line >= lines) {
    return;
  }
  var r = P.i0.x;
  if (P.head.z == 1u) {
    r = P.i0.y;
  } else if (P.head.z == 2u) {
    r = P.i0.z;
  }
  var a = vec2i(1, 0);
  var o = vec2i(0, line);
  if (!along_rows) {
    a = vec2i(0, 1);
    o = vec2i(line, 0);
  }
  if (r <= 0) {
    for (var i = 0; i < n; i++) {
      textureStore(dst, o + a * i, load(o + a * i));
    }
    return;
  }
  let inv = 1.0 / f32(2 * r + 1);
  var acc = vec4f(0.0);
  for (var i = 0; i < min(r, n); i++) {
    acc += load(o + a * i);
  }
  for (var i = 0; i < n; i++) {
    if (i + r < n) {
      acc += load(o + a * (i + r));
    }
    if (i > r) {
      acc -= load(o + a * (i - r - 1));
    }
    textureStore(dst, o + a * i, acc * inv);
  }
}

// The progressive blur: each pixel gathers with the Gaussian of its own sigma, linear
// along the ramp from `start` to `start + dir` (node space) and held past its ends.
@compute @workgroup_size(8, 8)
fn progressive(@builtin(global_invocation_id) id: vec3u) {
  let p = vec2i(id.xy);
  if (!inside(p)) {
    return;
  }
  // f0: inv a, b, c, d; f1: inv e, f, start; f2: dir, len2, s0; f3: s1, reach.
  let d = vec2f(f32(P.size.z + p.x) + 0.5, f32(P.size.w + p.y) + 0.5);
  let q = vec2f(P.f0.x * d.x + P.f0.z * d.y + P.f1.x, P.f0.y * d.x + P.f0.w * d.y + P.f1.y) - P.f1.zw;
  let len2 = P.f2.z;
  var sigma = P.f3.x;
  if (len2 > 1e-9) {
    let t = clamp((q.x * P.f2.x + q.y * P.f2.y) / len2, 0.0, 1.0);
    sigma = P.f2.w + (P.f3.x - P.f2.w) * t;
  }
  // The CPU's kernels by sigma, in steps of 1/16 px.
  let s = round(max(sigma, 0.0) * 16.0) / 16.0;
  var r = 0;
  if (s >= 0.05) {
    r = i32(max(1.0, round(s * P.f3.y)));
  }
  textureStore(dst, p, gather(p, s, r));
}

// --------------------------------------------------------------------------- spread

// A square max (grow) or min (shrink) filter of half width `i0.x` and one wider, rows
// into r and g, then columns of each, blended by the fraction `f0.x` (`spreadAlpha`).
@compute @workgroup_size(8, 8)
fn spread(@builtin(global_invocation_id) id: vec3u) {
  let p = vec2i(id.xy);
  if (!inside(p)) {
    return;
  }
  let a = axis();
  let r = P.i0.x;
  let grow = P.i0.y != 0;
  var lo = 0.0;
  var hi = 0.0;
  var first = true;
  for (var i = -(r + 1); i <= r + 1; i++) {
    let t = load(p + a * i);
    var vlo = t.a;
    var vhi = t.a;
    if (P.head.y == 1u) {
      vlo = t.r;
      vhi = t.g;
    }
    let near = i >= -r && i <= r;
    if (first) {
      hi = vhi;
      lo = select(select(1.0, 0.0, grow), vlo, near);
      first = false;
    } else if (grow) {
      hi = max(hi, vhi);
      if (near) {
        lo = max(lo, vlo);
      }
    } else {
      hi = min(hi, vhi);
      if (near) {
        lo = min(lo, vlo);
      }
    }
  }
  if (P.head.y == 0u) {
    textureStore(dst, p, vec4f(lo, hi, 0.0, 0.0));
  } else {
    let v = lo + (hi - lo) * P.f0.x;
    textureStore(dst, p, vec4f(v));
  }
}

// --------------------------------------------------------------------------- grain

fn hash(x: i32, y: i32, seed: u32) -> u32 {
  var v = bitcast<u32>(x) * 0x8da6b343u;
  v ^= bitcast<u32>(y) * 0xd8163841u;
  v ^= seed * 0xcb1ab31fu;
  v ^= v >> 16u;
  v *= 0x7feb352du;
  v ^= v >> 15u;
  v *= 0x846ca68bu;
  v ^= v >> 16u;
  return v;
}

fn unit(v: u32) -> f32 {
  return f32(v >> 8u) / 16777216.0;
}

// `effects.valueNoise`: a random value per lattice point (the lattice turned about 34
// degrees), smoothstep between them.
fn value_noise(p0: vec2f, seed: u32) -> f32 {
  let c = 0.8253356;
  let s = 0.5646425;
  let p = vec2f(p0.x * c - p0.y * s, p0.x * s + p0.y * c);
  let fx = floor(p.x);
  let fy = floor(p.y);
  let ix = i32(clamp(fx, -1e9, 1e9));
  let iy = i32(clamp(fy, -1e9, 1e9));
  var tx = p.x - fx;
  var ty = p.y - fy;
  tx = tx * tx * (3.0 - 2.0 * tx);
  ty = ty * ty * (3.0 - 2.0 * ty);
  let a = unit(hash(ix, iy, seed));
  let b = unit(hash(ix + 1, iy, seed));
  let cc = unit(hash(ix, iy + 1, seed));
  let d = unit(hash(ix + 1, iy + 1, seed));
  let top = a + (b - a) * tx;
  let bot = cc + (d - cc) * tx;
  return top + (bot - top) * ty;
}

fn grain_cover(v: f32, density: f32) -> f32 {
  let t = 1.0 - P.f4.z * clamp(density, 0.0, 1.0);
  return clamp((v - t) / P.f4.w, 0.0, 1.0);
}

fn channel(v: f32) -> f32 {
  return clamp(0.5 + (v - 0.5) * 1.2, 0.0, 1.0);
}

fn atop(d: vec4f, s: vec4f) -> vec4f {
  return vec4f(s.rgb * d.a + d.rgb * (1.0 - s.a), d.a);
}

// `effects.drawNoise`. f0: inv a, b, c, d; f1: inv e, f, cell; f2: density, colour rgb;
// f3: colour a, secondary rgb; f4: secondary a, opacity, density k, grain edge.
// i0: noise type, samples per side.
@compute @workgroup_size(8, 8)
fn noise(@builtin(global_invocation_id) id: vec3u) {
  let p = vec2i(id.xy);
  if (!inside(p)) {
    return;
  }
  var d = load(p);
  if (d.a <= 0.0) {
    textureStore(dst, p, d);
    return;
  }
  let kind = P.i0.x;
  let ss = P.i0.y;
  let ssf = f32(ss);
  let inv_n = 1.0 / (ssf * ssf);
  let dx = f32(P.size.z + p.x);
  let dy = f32(P.size.w + p.y);
  let cell = P.f1.zw;
  let density = P.f2.x;
  var hi = 0.0;
  var lo = 0.0;
  var mc = vec4f(0.0);
  for (var sy = 0; sy < ss; sy++) {
    for (var sx = 0; sx < ss; sx++) {
      let x = dx + (f32(sx) + 0.5) / ssf;
      let y = dy + (f32(sy) + 0.5) / ssf;
      let q = vec2f(P.f0.x * x + P.f0.z * y + P.f1.x, P.f0.y * x + P.f0.w * y + P.f1.y);
      let g = q / cell;
      if (kind == 2) {
        let v = value_noise(g, 2u);
        let c = grain_cover(v, density) + grain_cover(1.0 - v, density);
        if (c > 0.0) {
          let cg = g * 0.8;
          mc += vec4f(c * channel(value_noise(cg, 3u)), c * channel(value_noise(cg, 4u)), c * channel(value_noise(cg, 5u)), c);
        }
      } else {
        let v = value_noise(g, 1u);
        hi += grain_cover(v, density);
        if (kind == 1) {
          lo += grain_cover(1.0 - v, density);
        }
      }
    }
  }
  let pc = vec4f(P.f2.yzw, P.f3.x);
  let sc = vec4f(P.f3.yzw, P.f4.x);
  if (kind == 0) {
    if (hi > 0.0) {
      let a = pc.a * hi * inv_n;
      d = atop(d, vec4f(pc.rgb * a, a));
    }
  } else if (kind == 1) {
    if (hi > 0.0) {
      let a = sc.a * hi * inv_n;
      d = atop(d, vec4f(sc.rgb * a, a));
    }
    if (lo > 0.0) {
      let a = pc.a * lo * inv_n;
      d = atop(d, vec4f(pc.rgb * a, a));
    }
  } else if (mc.a > 0.0) {
    d = atop(d, mc * (P.f4.y * inv_n));
  }
  textureStore(dst, p, d);
}

fn signed_noise(g: vec2f, seed: u32) -> f32 {
  let a = value_noise(g, seed) * 2.0 - 1.0;
  let b = value_noise(g * 2.0, seed + 100u) * 2.0 - 1.0;
  return a + 0.5 * b;
}

// `effects.drawTexture`. f0: inv a, b, c, d; f1: inv e, f, ctm a, b; f2: ctm c, d, cell;
// f3: amplitude. i0: clip.
@compute @workgroup_size(8, 8)
fn texture(@builtin(global_invocation_id) id: vec3u) {
  let p = vec2i(id.xy);
  if (!inside(p)) {
    return;
  }
  let cx = f32(P.size.z + p.x) + 0.5;
  let cy = f32(P.size.w + p.y) + 0.5;
  let q = vec2f(P.f0.x * cx + P.f0.z * cy + P.f1.x, P.f0.y * cx + P.f0.w * cy + P.f1.y);
  let g = q / P.f2.zw;
  let amp = P.f3.x;
  let vx = amp * signed_noise(g, 21u);
  let vy = amp * signed_noise(g, 22u);
  let off = vec2f(P.f1.z * vx + P.f2.x * vy, P.f1.w * vx + P.f2.y * vy);
  // `effects.bilinear`: texel centres at .5, clear outside.
  let f = vec2f(cx + off.x - 0.5 - f32(P.size.z), cy + off.y - 0.5 - f32(P.size.w));
  let f0 = floor(f);
  let t = f - f0;
  var out = vec4f(0.0);
  let w = f32(P.size.x);
  let h = f32(P.size.y);
  if (!(f0.x < -2.0 || f0.y < -2.0 || f0.x > w || f0.y > h)) {
    let i = vec2i(f0);
    out = load(i) * (1.0 - t.x) * (1.0 - t.y) + load(i + vec2i(1, 0)) * t.x * (1.0 - t.y) + load(i + vec2i(0, 1)) * (1.0 - t.x) * t.y + load(i + vec2i(1, 1)) * t.x * t.y;
  }
  if (P.i0.x != 0) {
    // The displaced colour at the node's own coverage.
    let o = load(p);
    if (out.a > 1e-4) {
      let k = o.a / out.a;
      out = vec4f(out.rgb * k, o.a);
    } else {
      out = o;
    }
  }
  textureStore(dst, p, out);
}

// --------------------------------------------------------------------------- backdrop

fn mirror(i: i32, lo: i32, hi: i32) -> i32 {
  if (hi <= lo) {
    return lo;
  }
  var v = i;
  if (v < lo) {
    v = lo + (lo - v - 1);
  }
  if (v >= hi) {
    v = hi - 1 - (v - hi);
  }
  return clamp(v, lo, hi - 1);
}

// What is drawn under a background blur: the target's pixels (`src`), mirrored at the
// node's bounds (`i0`, top space). Target texel = top + `i1.xy`.
@compute @workgroup_size(8, 8)
fn backdrop(@builtin(global_invocation_id) id: vec3u) {
  let p = vec2i(id.xy);
  if (!inside(p)) {
    return;
  }
  var t = vec2i(P.size.z + p.x, P.size.w + p.y);
  if (P.i1.z != 0) {
    t = vec2i(mirror(t.x, P.i0.x, P.i0.z), mirror(t.y, P.i0.y, P.i0.w));
  }
  textureStore(dst, p, load_in(t + P.i1.xy, vec2i(textureDimensions(src, 0))));
}
