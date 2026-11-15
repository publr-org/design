// The GPU canvas from records (`records.zig`, docs/gpu.md "Records"): the page's prims
// kept on the GPU in their nodes' units, drawn through each top-level node's camera.
//
// A prim's node matrix (the transform table) after its top-level node's camera is the
// CPU's `ctm` for that node: shapes, paints and clips are evaluated through it at the
// pixel, so the numbers are the CPU's (top space, Figma's 16 sample points) at any scale.

struct Frame {
  // The target's size.
  size: vec2f,
  // Added to every camera's whole-pixel offset (target pixels).
  off: vec2i,
  // Where in `framebuf` the images' held state starts (vec4s); where in `geo` the bands
  // and their curves start (words).
  held_off: u32,
  bands_off: u32,
  items_off: u32,
  // Debugging switches (0).
  pad: u32,
  // Where in `geo` the masks start (words).
  masks_off: u32,
  // The mask being drawn (`mask_fs`).
  mask_now: u32,
  // Where in `framebuf` the items' pictures are described (vec4s, four an item).
  item_table: u32,
  pad2: u32,
}

struct RPrim {
  // Where it may paint, top-level units.
  bounds: vec4f,
  // shape, shape2, clip, paint
  refs: vec4u,
  // op, xf, top, feature
  misc: vec4u,
  // opacity (f32 bits), blend, mask, margin (f32 bits)
  extra: vec4u,
}

struct RShape {
  // kind, next, xf, flags
  head: vec4u,
  v0: vec4f,
  v1: vec4f,
  v2: vec4f,
  v3: vec4f,
  v4: vec4f,
  v5: vec4f,
  v6: vec4f,
}

struct Xform {
  m: vec4f,
  t: vec4f,
}

struct CurveRec {
  p: vec4f,
  q: vec4f,
}

struct Held {
  size: vec2f,
  levels: u32,
  ready: u32,
}

fn held_at(i: u32) -> Held {
  let v = framebuf[frame.held_off + i];
  return Held(v.xy, bitcast<u32>(v.z), bitcast<u32>(v.w));
}

const RSHAPE_RECT: u32 = 1u;
const RSHAPE_ELLIPSE: u32 = 2u;
const RSHAPE_PATH: u32 = 3u;
const RSHAPE_GLYPH: u32 = 4u;

@group(0) @binding(0) var<uniform> frame: Frame;
@group(0) @binding(1) var<storage, read> prims: array<RPrim>;
@group(0) @binding(2) var<storage, read> shapes: array<RShape>;
@group(0) @binding(3) var<storage, read> paints: array<Paint>;
@group(0) @binding(4) var<storage, read> stops: array<vec4f>;
@group(0) @binding(5) var<storage, read> xforms: array<Xform>;
// The frame's cameras (two vec4s each), then the images' held state (one each).
@group(0) @binding(6) var<storage, read> framebuf: array<vec4f>;
@group(0) @binding(7) var<storage, read> curves: array<CurveRec>;
@group(0) @binding(8) var<storage, read> geo: array<u32>;
@group(0) @binding(9) var masks: texture_2d_array<f32>;
@group(0) @binding(10) var mask_sampler: sampler;
// The items' pictures (premultiplied RGBA8), in layers.
@group(0) @binding(11) var item_atlas: texture_2d_array<f32>;

const PAINT_ITEM: u32 = 10u;

// An item's picture: none yet (`state` 0), or where it is in the atlas, the top-space
// rect it covers and the matrix it was drawn at.
struct ItemPic {
  state: u32,
  layer: u32,
  at: vec2i,
  size: vec2i,
  origin: vec2i,
  ctm: Aff,
  parent: u32,
}

fn item_pic(i: u32) -> ItemPic {
  let o = frame.item_table + i * 4u;
  let a = bitcast<vec4u>(framebuf[o]);
  let b = bitcast<vec4i>(framebuf[o + 1u]);
  let c = framebuf[o + 2u];
  let d = framebuf[o + 3u];
  return ItemPic(a.x, a.y, vec2i(a.zw), b.xy, b.zw, Aff(c, d.xy), bitcast<u32>(d.z));
}

// Whether a prim standing in for item `owner` (and the items around it) is hidden: one
// of them has a picture.
fn owned_hidden(owner: u32) -> bool {
  var i = owner;
  var guard = 0u;
  loop {
    if (i == NONE || guard >= 32u) {
      return false;
    }
    let o = frame.item_table + i * 4u;
    if (bitcast<u32>(framebuf[o].x) != 0u) {
      return true;
    }
    i = bitcast<u32>(framebuf[o + 3u].z);
    guard++;
  }
}

// An item's picture at pixel `px` (top space; `ctm` the item node's matrix now): its
// texel when drawn at this matrix, else the picture of another matrix mapped here,
// bilinear.
fn item_at(pic: ItemPic, ctm: Aff, px: vec2f) -> vec4f {
  // The same matrix (to float noise: the host and this shader multiply the camera in).
  let tol = 1e-5 * max(abs(ctm.m.x) + abs(ctm.m.y), abs(ctm.m.z) + abs(ctm.m.w));
  let same = all(abs(pic.ctm.m - ctm.m) <= vec4f(tol)) && all(abs(pic.ctm.t - ctm.t) <= vec2f(1e-3));
  if (same) {
    let t = vec2i(px) - pic.origin;
    if (any(t < vec2i(0)) || any(t >= pic.size)) {
      return vec4f(0.0);
    }
    return textureLoad(item_atlas, pic.at + t, pic.layer, 0);
  }
  let q = aff_apply(pic.ctm, aff_apply(aff_invert(ctm), px + 0.5)) - vec2f(pic.origin) - 0.5;
  let f0 = floor(q);
  let k = q - f0;
  let i0 = vec2i(f0);
  var acc = vec4f(0.0);
  for (var j = 0; j < 4; j++) {
    let d = vec2i(j & 1, j >> 1);
    let t = i0 + d;
    if (any(t < vec2i(0)) || any(t >= pic.size)) {
      continue;
    }
    let w = mix(1.0 - k.x, k.x, f32(d.x)) * mix(1.0 - k.y, k.y, f32(d.y));
    acc += textureLoad(item_atlas, pic.at + t, pic.layer, 0) * w;
  }
  return acc;
}

struct MaskRec {
  path: u32,
  layer: u32,
  size: vec2f,
  origin: vec2f,
  k: f32,
  evenodd: bool,
}

fn mask_rec(i: u32) -> MaskRec {
  let o = frame.masks_off + i * 8u;
  return MaskRec(geo[o], geo[o + 1u], vec2f(f32(geo[o + 2u]), f32(geo[o + 3u])), vec2f(bitcast<f32>(geo[o + 4u]), bitcast<f32>(geo[o + 5u])), bitcast<f32>(geo[o + 6u]), (geo[o + 7u] & 1u) != 0u);
}

// Coverage from mask `m` at pixel `px` (top space; `full` the path's units to it): the
// mask under the pixel, from the level whose texels are about the pixel's size.
fn mask_cov(m: MaskRec, full: Aff, px: vec2f) -> f32 {
  let inv = aff_invert(full);
  let q = (aff_apply(inv, px + 0.5) - m.origin) * m.k;
  let lod = log2(max(m.k / max(aff_max_scale(full), 1e-12), 1.0));
  let dim = vec2f(textureDimensions(masks, 0));
  return textureSampleLevel(masks, mask_sampler, q / dim, m.layer, lod).r;
}

// A path's mask, drawn once: each texel the curves' coverage at its 16 samples.
@vertex
fn mask_vs(@builtin(vertex_index) vi: u32) -> @builtin(position) vec4f {
  let p = vec2f(f32((vi << 1u) & 2u), f32(vi & 2u));
  return vec4f(p * 2.0 - 1.0, 0.0, 1.0);
}

@fragment
fn mask_fs(@builtin(position) pos: vec4f) -> @location(0) vec4f {
  let m = mask_rec(frame.mask_now);
  let px = floor(pos.xy);
  if (px.x >= m.size.x || px.y >= m.size.y) {
    return vec4f(0.0);
  }
  // Path units to texels.
  let t = Aff(vec4f(m.k, 0.0, 0.0, m.k), -m.origin * m.k);
  return vec4f(path_cov_curves(m.path, t, t, false, px, m.evenodd));
}


@group(1) @binding(0) var tex: texture_2d<f32>;

struct VOut {
  @builtin(position) pos: vec4f,
  @location(0) @interpolate(flat) prim: u32,
}

fn camera(top: u32) -> Aff {
  return Aff(framebuf[top * 2u], framebuf[top * 2u + 1u].xy);
}

fn cam_origin(top: u32) -> vec2f {
  let t = framebuf[top * 2u + 1u];
  return vec2f(f32(bitcast<i32>(t.z) + frame.off.x), f32(bitcast<i32>(t.w) + frame.off.y));
}

fn xform(i: u32) -> Aff {
  let x = xforms[i];
  return Aff(x.m, x.t.xy);
}

@vertex
fn vs(@builtin(vertex_index) vi: u32, @builtin(instance_index) ii: u32) -> VOut {
  let p = prims[ii];
  var out: VOut;
  out.prim = ii;
  // An item's stand-in while it has a picture, or its composite while it has none.
  var hidden = p.extra.z != NONE && owned_hidden(p.extra.z);
  if (paints[p.refs.w].head.x == PAINT_ITEM && item_pic(paints[p.refs.w].head.z).state == 0u) {
    hidden = true;
  }
  if (hidden) {
    out.pos = vec4f(-2.0, -2.0, 0.0, 1.0);
    return out;
  }
  let cam = camera(p.misc.z);
  let o = cam_origin(p.misc.z);
  let b = p.bounds;
  let c0 = aff_apply(cam, b.xy);
  let c1 = aff_apply(cam, b.zy);
  let c2 = aff_apply(cam, b.xw);
  let c3 = aff_apply(cam, b.zw);
  let margin = bitcast<f32>(p.extra.w);
  var lo = floor(min(min(c0, c1), min(c2, c3)) + o - margin);
  var hi = ceil(max(max(c0, c1), max(c2, c3)) + o + margin);
  // Off the target (or empty): nothing to draw.
  lo = max(lo, vec2f(-1.0));
  hi = min(hi, frame.size + 1.0);
  if (!(hi.x > lo.x && hi.y > lo.y)) {
    out.pos = vec4f(-2.0, -2.0, 0.0, 1.0);
    return out;
  }
  let corner = vec2f(f32(vi & 1u), f32(vi >> 1u));
  let xy = mix(lo, hi, corner);
  out.pos = vec4f(xy.x / frame.size.x * 2.0 - 1.0, 1.0 - xy.y / frame.size.y * 2.0, 0.0, 1.0);
  return out;
}

fn upright_even(a: Aff) -> bool {
  return a.m.y == 0.0 && a.m.z == 0.0 && a.m.x == a.m.w && a.m.x > 0.0;
}

// A rectangle (or ellipse) of the node through `ctm`, as `Scene.rectShape` places it:
// in top space when upright and evenly scaled (the CPU's numbers), else in node space
// with the inverse.
fn formula_shape(s: RShape, ctm: Aff) -> Shape {
  var o: Shape;
  o.head = vec4u(s.head.x, 0u, 0u, s.head.w & 1u);
  o.outer = s.v0;
  o.outer_r = s.v1;
  o.inner = s.v2;
  o.inner_r = s.v3;
  o.inv = vec4f(1.0, 0.0, 0.0, 1.0);
  o.inv_t = vec4f(0.0);
  if (upright_even(ctm)) {
    let k = ctm.m.x;
    o.outer = vec4f(aff_apply(ctm, s.v0.xy), aff_apply(ctm, s.v0.zw));
    o.outer_r = s.v1 * k;
    o.inner = vec4f(aff_apply(ctm, s.v2.xy), aff_apply(ctm, s.v2.zw));
    o.inner_r = s.v3 * k;
  } else {
    let inv = aff_invert(ctm);
    o.inv = inv.m;
    o.inv_t = vec4f(inv.t, 0.0, 0.0);
  }
  return o;
}

// Coverage of record shape `i` at pixel `px` (top space of top-level node `top`).
fn rshape_cov(i: u32, cam: Aff, px: vec2f) -> f32 {
  let s = shapes[i];
  let ctm = aff_mul(cam, xform(s.head.z));
  let kind = s.head.x;
  if ((frame.pad & 1u) != 0u && (kind == RSHAPE_PATH || kind == RSHAPE_GLYPH)) {
    return 0.5;
  }
  if ((frame.pad & 4u) != 0u && kind == RSHAPE_GLYPH) {
    return 0.5;
  }
  if (kind == RSHAPE_PATH) {
    return path_cov(bitcast<u32>(s.v0.x), ctm, ctm, false, px, (s.head.w & 2u) != 0u);
  }
  if (kind == RSHAPE_GLYPH) {
    let gm = Aff(vec4f(s.v0.y, s.v0.z, s.v0.w, s.v1.x), s.v1.yz);
    return path_cov(bitcast<u32>(s.v0.x), gm, ctm, true, px, false);
  }
  return formula_cov(formula_shape(s, ctm), px);
}

fn rclip_cov(first: u32, cam: Aff, px: vec2f) -> f32 {
  var c = 1.0;
  var i = first;
  var guard = 0u;
  loop {
    if (i == NONE || guard >= 64u || c <= 0.0) {
      break;
    }
    c *= rshape_cov(i, cam, px);
    i = shapes[i].head.y;
    guard++;
  }
  return c;
}

// Paint `i` through `ctm` at device point `q` (top space): its node-space matrix after
// the inverse of `ctm`, then evaluated as `paint.wgsl` evaluates it.
fn rpaint_at(i: u32, ctm: Aff, q: vec2f) -> vec4f {
  var p = paints[i];
  let kind = p.head.x;
  if (kind == PAINT_SOLID) {
    return p.color;
  }
  let inv = aff_invert(ctm);
  if (kind >= PAINT_LINEAR && kind <= PAINT_DIAMOND) {
    let g = aff_mul(Aff(p.inv, p.inv_t.xy), inv);
    p.inv = g.m;
    p.inv_t = vec4f(g.t, 0.0, 0.0);
    return gradient(p, q);
  }
  if (kind == PAINT_IMAGE) {
    let h = held_at(p.head.z);
    if ((h.ready & 1u) == 0u) {
      return vec4f(0.0);
    }
    // Pixels of the full chain, as on the CPU: the texture holds its levels from the
    // held one on (`levels` counts the full chain to the last held).
    let g = aff_mul(Aff(p.inv, p.inv_t.xy), inv);
    p.inv = g.m;
    p.inv_t = vec4f(g.t, p.inv_t.zw);
    p.head.w = h.levels;
    return image(p, q);
  }
  if (kind == PAINT_SHADOW_FORMULA) {
    let x = paints[i + 1u];
    let s = aff_max_scale(ctm);
    let sigma = x.color.z * s * x.inv.x;
    let off = vec2f(ctm.m.x * x.color.x + ctm.m.z * x.color.y, ctm.m.y * x.color.x + ctm.m.w * x.color.y);
    var box = vec4f(aff_apply(ctm, p.inv.xy), aff_apply(ctm, p.inv.zw));
    var radii = p.inv_t * s;
    if ((p.head.y & 2u) != 0u) {
      // Inner: the box moved by the offset in whole pixels, shrunk by the spread.
      let ix = sign(off.x) * floor(abs(off.x) + 0.5);
      let iy = sign(off.y) * floor(abs(off.y) + 0.5);
      let d = x.color.w * s;
      box = vec4f(box.x + ix + d, box.y + iy + d, box.z + ix - d, box.w + iy - d);
      radii = select(vec4f(0.0), max(vec4f(0.0), radii - d), radii > vec4f(0.0));
    } else {
      box = box + vec4f(off, off);
    }
    p.inv = box;
    p.inv_t = radii;
    p.head.w = bitcast<u32>(sigma);
    var v = blurred_shape(p, q);
    if ((p.head.y & 2u) != 0u) {
      v = 1.0 - v;
    }
    return p.color * clamp(v, 0.0, 1.0);
  }
  return vec4f(0.0);
}

@fragment
fn fs(in: VOut) -> @location(0) vec4f {
  let p = prims[in.prim];
  if ((frame.pad & 2u) != 0u) {
    return vec4f(0.01);
  }
  let top = p.misc.z;
  let cam = camera(top);
  // The pixel's top left in top space.
  let px = floor(in.pos.xy) - cam_origin(top);
  var cov = bitcast<f32>(p.extra.x);
  if (p.refs.x != NONE) {
    cov *= rshape_cov(p.refs.x, cam, px);
  }
  if (cov > 0.0 && p.misc.x != 0u && p.refs.y != NONE) {
    let c2 = rshape_cov(p.refs.y, cam, px);
    if (p.misc.x == 1u) {
      cov *= c2;
    } else {
      cov *= 1.0 - c2;
    }
  }
  if (cov > 0.0 && p.refs.z != NONE) {
    cov *= rclip_cov(p.refs.z, cam, px);
  }
  if (cov <= 0.0) {
    discard;
  }
  let ctm = aff_mul(cam, xform(p.misc.y));
  let pt = paints[p.refs.w];
  if (pt.head.x == PAINT_ITEM) {
    return item_at(item_pic(pt.head.z), ctm, px) * cov;
  }
  return rpaint_at(p.refs.w, ctm, px + 0.5) * cov;
}
