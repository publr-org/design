// The path atlas: path coverage at twice the resolution with 4x MSAA (the standard 4x
// pattern there is Figma's 16 points per device pixel), by stencil and cover.
//
// Stencil: every contour as a fan of triangles from its first point, counting up on
// front faces and down on back faces, so each sample holds its winding number. Cover:
// a quad per atlas entry where the winding says inside (nonzero: any count; even-odd:
// odd counts) writes 1 and zeroes the stencil. The resolve averages each texel's four
// samples into the atlas layer.

struct Layer {
  size: vec2f,
  pad: vec2f,
}

@group(0) @binding(0) var<uniform> layer: Layer;

fn ndc(p: vec2f) -> vec4f {
  return vec4f(p.x / layer.size.x * 2.0 - 1.0, 1.0 - p.y / layer.size.y * 2.0, 0.0, 1.0);
}

@vertex
fn stencil_vs(@location(0) p: vec2f) -> @builtin(position) vec4f {
  return ndc(p);
}

@fragment
fn stencil_fs() -> @location(0) vec4f {
  return vec4f(0.0);
}

// One entry's texels: x, y, w, h.
@vertex
fn cover_vs(@builtin(vertex_index) vi: u32, @location(0) r: vec4u) -> @builtin(position) vec4f {
  let corner = vec2f(f32(vi & 1u), f32(vi >> 1u));
  let rf = vec4f(r);
  return ndc(rf.xy + rf.zw * corner);
}

@fragment
fn cover_fs() -> @location(0) vec4f {
  return vec4f(1.0, 0.0, 0.0, 1.0);
}

// Glyph masks (one texel per device pixel, from the glyph atlas) added into an entry:
// each mask texel over its 2x2 texels, coverage summed with what is there.

@group(0) @binding(1) var glyphs: texture_2d<f32>;

struct GlyphOut {
  @builtin(position) pos: vec4f,
  @location(0) @interpolate(flat) dst: vec2f,
  @location(1) @interpolate(flat) src: vec2f,
}

// a: layer, dx, dy, w; b: h, sx, sy, unused.
@vertex
fn glyph_vs(@builtin(vertex_index) vi: u32, @location(0) a: vec4u, @location(1) b: vec4u) -> GlyphOut {
  let corner = vec2f(f32(vi & 1u), f32(vi >> 1u));
  let dst = vec2f(f32(a.y), f32(a.z));
  let size = vec2f(f32(a.w), f32(b.x)) * 2.0;
  var out: GlyphOut;
  out.pos = ndc(dst + size * corner);
  out.dst = dst;
  out.src = vec2f(f32(b.y), f32(b.z));
  return out;
}

@fragment
fn glyph_fs(in: GlyphOut) -> @location(0) vec4f {
  let local = vec2i(floor((floor(in.pos.xy) - in.dst) * 0.5));
  let v = textureLoad(glyphs, vec2i(in.src) + local, 0).r;
  return vec4f(v, 0.0, 0.0, 1.0);
}
