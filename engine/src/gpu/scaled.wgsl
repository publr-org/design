// A kept view at another scale or place, as a stand-in (while the zoom changes, and
// under the parts of a new view not built yet): source texel `at + pixel * step`
// (bilinear, between texel centres), `bg` past its edges. At step 1 and a whole `at` it is
// a copy.

struct Scaled {
  at: vec2f,
  step: vec2f,
  bg: vec4f,
}

@group(0) @binding(0) var src: texture_2d<f32>;
@group(0) @binding(1) var<uniform> scaled: Scaled;

@vertex
fn vs(@builtin(vertex_index) vi: u32) -> @builtin(position) vec4f {
  let p = vec2f(f32((vi << 1u) & 2u), f32(vi & 2u));
  return vec4f(p.x * 2.0 - 1.0, 1.0 - p.y * 2.0, 0.0, 1.0);
}

fn texel(p: vec2i, size: vec2i) -> vec4f {
  if (p.x < 0 || p.y < 0 || p.x >= size.x || p.y >= size.y) {
    return scaled.bg;
  }
  return textureLoad(src, p, 0);
}

@fragment
fn fs(@builtin(position) pos: vec4f) -> @location(0) vec4f {
  let size = vec2i(textureDimensions(src));
  let p = scaled.at + pos.xy * scaled.step - 0.5;
  let i = floor(p);
  let f = p - i;
  let q = vec2i(i);
  let a = mix(texel(q, size), texel(q + vec2i(1, 0), size), f.x);
  let b = mix(texel(q + vec2i(0, 1), size), texel(q + vec2i(1, 1), size), f.x);
  return mix(a, b, f.y);
}
