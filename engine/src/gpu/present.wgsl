// The frame onto the canvas: the float target's premultiplied pixels, as they are, from
// inside the apron the target holds around the view.

struct Present {
  offset: vec2f,
  pad: vec2f,
}

@group(0) @binding(0) var src: texture_2d<f32>;
@group(0) @binding(1) var<uniform> present: Present;

@vertex
fn vs(@builtin(vertex_index) vi: u32) -> @builtin(position) vec4f {
  let p = vec2f(f32((vi << 1u) & 2u), f32(vi & 2u));
  return vec4f(p.x * 2.0 - 1.0, 1.0 - p.y * 2.0, 0.0, 1.0);
}

@fragment
fn fs(@builtin(position) pos: vec4f) -> @location(0) vec4f {
  return textureLoad(src, vec2i(floor(pos.xy) + present.offset), 0);
}
