// PublrEngine's GPU canvas: one pipeline draws every primitive of a frame.
//
// A primitive is a quad over its pixels (`Prim`, see docs/gpu.md). Its colour is its
// paint (solid, gradient, image, or a CPU layer) at the pixel's centre, as the CPU's
// shaders evaluate it; its coverage is the share of Figma's 16 sample points inside its
// shape (a formula here, or the path atlas the stencil pass filled), times the coverage of
// its second shape when it has one (kept or cut out), of every clip in its chain, of its
// mask paint, and its opacity. Colours are premultiplied and composited source-over into a
// float target, as the CPU composites; a blend mode reads a copy of what is under the
// prim (`backdrop`) and writes the result (`pixmap.blendPixel`).

struct Frame {
  size: vec2f,
  flags: u32,
  pad: u32,
}

struct Prim {
  bounds: vec4f,
  // shape, shape2, clip, paint
  refs: vec4u,
  // op, ox, oy (i32 bits), feature
  misc: vec4u,
  // opacity (f32 bits), blend | mask mode << 8, mask paint, unused
  extra: vec4u,
}

@group(0) @binding(0) var<uniform> frame: Frame;
@group(0) @binding(1) var<storage, read> prims: array<Prim>;
@group(0) @binding(2) var<storage, read> shapes: array<Shape>;
@group(0) @binding(3) var<storage, read> paints: array<Paint>;
@group(0) @binding(4) var<storage, read> stops: array<vec4f>;
@group(0) @binding(5) var atlas: texture_2d_array<f32>;
@group(1) @binding(0) var tex: texture_2d<f32>;
// What lies under the prim (blend modes), from the prim's top left.
@group(1) @binding(1) var backdrop: texture_2d<f32>;
// The texture the mask paint reads.
@group(1) @binding(2) var mask_tex: texture_2d<f32>;

struct VOut {
  @builtin(position) pos: vec4f,
  @location(0) @interpolate(flat) prim: u32,
}

@vertex
fn vs(@builtin(vertex_index) vi: u32, @builtin(instance_index) ii: u32) -> VOut {
  let p = prims[ii];
  let corner = vec2f(f32(vi & 1u), f32(vi >> 1u));
  let xy = mix(p.bounds.xy, p.bounds.zw, corner);
  var out: VOut;
  out.pos = vec4f(xy.x / frame.size.x * 2.0 - 1.0, 1.0 - xy.y / frame.size.y * 2.0, 0.0, 1.0);
  out.prim = ii;
  return out;
}

// Coverage from the path atlas: the four texels (2x2 at twice the resolution, four
// samples each) of pixel `px`.
fn atlas_cov(s: Shape, px: vec2f) -> f32 {
  let r = s.outer;
  if (px.x < r.x || px.y < r.y || px.x >= r.z || px.y >= r.w) {
    return 0.0;
  }
  let t = vec2i(s.outer_r.xy + (px - r.xy) * 2.0);
  let layer = i32(s.head.z);
  let v = textureLoad(atlas, t, layer, 0).r + textureLoad(atlas, t + vec2i(1, 0), layer, 0).r
    + textureLoad(atlas, t + vec2i(0, 1), layer, 0).r + textureLoad(atlas, t + vec2i(1, 1), layer, 0).r;
  return v * 0.25;
}

fn shape_cov(i: u32, px: vec2f) -> f32 {
  let s = shapes[i];
  if (s.head.x == SHAPE_ATLAS) {
    return atlas_cov(s, px);
  }
  return formula_cov(s, px);
}

fn clip_cov(first: u32, px: vec2f) -> f32 {
  var c = 1.0;
  var i = first;
  var guard = 0u;
  loop {
    if (i == NONE || guard >= 64u || c <= 0.0) {
      break;
    }
    c *= shape_cov(i, px);
    i = shapes[i].head.y;
    guard++;
  }
  return c;
}

// A surface (or a CPU layer): its texel under the pixel, or bilinear when filtered.
fn layer(t: texture_2d<f32>, p: Paint, q: vec2f) -> vec4f {
  let at = paint_apply(p, q);
  if ((p.head.y & 1u) == 0u) {
    let dim = vec2i(textureDimensions(t, 0));
    return layer_texel(t, i32(clamp(floor(at.x), -1e8, 1e8)), i32(clamp(floor(at.y), -1e8, 1e8)), dim);
  }
  return bilinear(t, at - 0.5);
}

fn paint_at(i: u32, q: vec2f) -> vec4f {
  let p = paints[i];
  let kind = p.head.x;
  if (kind == PAINT_SOLID) {
    return p.color;
  }
  if (kind >= PAINT_LINEAR && kind <= PAINT_DIAMOND) {
    return gradient(p, q);
  }
  if (kind == PAINT_IMAGE) {
    return image(p, q);
  }
  if (kind == PAINT_TEXTURE) {
    return layer(tex, p, q);
  }
  if (kind == PAINT_SHADOW) {
    return p.color * bilinear(tex, paint_apply(p, q) - 0.5).a;
  }
  if (kind == PAINT_SHADOW_FORMULA) {
    var v = blurred_shape(p, q);
    if ((p.head.y & 2u) != 0u) {
      v = 1.0 - v;
    }
    return p.color * clamp(v, 0.0, 1.0);
  }
  return vec4f(0.0);
}

// The mask paint's value at `q`.
fn mask_at(i: u32, mode: u32, q: vec2f) -> f32 {
  let t = layer(mask_tex, paints[i], q);
  if (mode == MASK_LUMINANCE) {
    return 0.2126 * t.r + 0.7152 * t.g + 0.0722 * t.b;
  }
  if (mode == MASK_INVERSE_ALPHA) {
    return 1.0 - t.a;
  }
  return t.a;
}

@fragment
fn fs(in: VOut) -> @location(0) vec4f {
  let p = prims[in.prim];
  let origin = vec2f(f32(bitcast<i32>(p.misc.y)), f32(bitcast<i32>(p.misc.z)));
  // The pixel's top left in top space.
  let px = floor(in.pos.xy) - origin;
  var cov = bitcast<f32>(p.extra.x);
  if (p.refs.x != NONE) {
    cov *= shape_cov(p.refs.x, px);
  }
  if (cov > 0.0 && p.misc.x != 0u) {
    let c2 = shape_cov(p.refs.y, px);
    if (p.misc.x == 1u) {
      cov *= c2;
    } else {
      cov *= 1.0 - c2;
    }
  }
  if (cov > 0.0 && p.refs.z != NONE) {
    cov *= clip_cov(p.refs.z, px);
  }
  let mode = p.extra.y & 0xffu;
  let mask_mode = (p.extra.y >> 8u) & 0xffu;
  if (cov > 0.0 && mask_mode != 0u) {
    cov *= mask_at(p.extra.z, mask_mode, px + 0.5);
  }
  if (mode == 0u) {
    if (cov <= 0.0) {
      discard;
    }
    return paint_at(p.refs.w, px + 0.5) * cov;
  }
  // A prim that reads the backdrop replaces the target's texels (no blend state): where
  // it leaves a texel as it was, it writes the backdrop back rather than discarding (a
  // discarded texel of such a pass comes out clear on some GPUs).
  let d = textureLoad(backdrop, vec2i(floor(in.pos.xy) - floor(p.bounds.xy)), 0);
  if (cov <= 0.0) {
    return d;
  }
  let s = paint_at(p.refs.w, px + 0.5);
  if (mode == BLEND_LERP) {
    return d + (s - d) * cov;
  }
  // A layer composite skips clear texels, as `drawPixmapBlend` does.
  if (s.a <= 0.0) {
    return d;
  }
  return blend_pixel(d, s, cov, mode);
}
