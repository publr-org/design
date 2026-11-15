# The GPU frame

The GPU canvas (`../.agents/specs/publr-design-gpu.md` in the workspace) draws a frame the
engine writes into its memory: the scene walked as the CPU renderer walks it
(`src/gpu/scene.zig`), flattened into lists in draw order. The host (in the browser,
`editor/viewer/gpu.ts`) uploads the lists and draws them with the shaders in `src/gpu/`
(`paint.wgsl`, `atlas.wgsl`, `present.wgsl`, `effects.wgsl`, also served by
`pe_gpu_shader`).

Layout version 3. Every record is little-endian 32-bit words (`u32`, `i32` or `f32`),
with no padding beyond what is listed. Addresses are byte offsets into the engine's
memory; they hold until the next call into the engine.

A native host (`../native`) imports the engine as Zig and reads the same records from
the `Scene`'s lists instead: addresses there would need 64 bits. Two things the header
points at have their own lists for it: `Scene.fallback_ids` (each fallback's node id) and
`Scene.texture_hashes`; a glyph upload's `ptr` is natively its offset into
`Scene.glyph_bytes`.

## Calls (wasm)

| Call | Does |
|---|---|
| `pe_gpu_new()` | a frame builder (keeps node-space paths and text between frames) |
| `pe_gpu_forget(sc)` | drops what it keeps; call when the document changes |
| `pe_gpu_page(sc, s, page, x, y, scale, w, h)` | the frame of `w` x `h` device pixels of a page, world (`x`, `y`) at the top left; answers the header's address |
| `pe_gpu_node(sc, s, id, len, scale, w, h)` | the frame of a node as an export draws it (its box at `scale`, top left at 0, 0) |
| `pe_gpu_texture_level(sc, tex, level)` | address of a texture's mip level (RGBA8, `w * h * 4` bytes; level 0 straight alpha, the others premultiplied); its size in `pe_result_width`/`height` |
| `pe_gpu_shader(which)` | WGSL source: 0 primitives, 1 path atlas, 2 canvas, 3 effect passes |
| `pe_gpu_motion(sc, on)` | the view is moving: glyph masks and polylines of nearby scales stand in (see Motion) |
| `pe_gpu_formula(on)` | shadows of rectangles and ellipses by formula (default) or by passes, to compare |
| `pe_render_layer(s, id, len, part, child, a, b, c, d, e, f, x0, y0, w, h)` | a fallback: part of a node on the CPU under that matrix into that device rect, premultiplied RGBA8 |

## Coordinates

Each top-level node is drawn in its own device space, *top space*: the space a CPU tile
draws it in (`Session.place`). Its origin lies at a fraction of a pixel; the whole-pixel
offset to the viewport is on every primitive (`ox`, `oy`). Shapes, paints, clips, atlas
entries and fallbacks are in top space, so their numbers are the CPU's, and they stay
the same while the view pans by whole device pixels. A pixel `p` of the viewport is
pixel `p - (ox, oy)` of top space; paints are evaluated at its centre, coverage at
Figma's 16 sample points in it (`mask.figma16`).

A page frame's target holds `apron` pixels more on each side than the view (what a
background blur reads past the view's edge, as a CPU tile's apron): viewport pixel `p` is
target pixel `p + apron`, and the offsets on the prims include it. Inside a surface the
target is the surface: its texel `t` is top-space pixel `t + (x0, y0)`, so its prims carry
`(-x0, -y0)`. A coarse surface (blurs wider than `coarse_sigma`) is drawn in the coarse
grid's space (`Coarse.ctmFor`) and scaled up bilinear when composited.

## Header (59 words)

| Word | Field |
|---|---|
| 0 | version (3) |
| 1, 2 | prims: address, count |
| 3, 4 | shapes |
| 5, 6 | paints |
| 7, 8 | stops (count in vec4s) |
| 9, 10 | draws |
| 11, 12 | atlas entries |
| 13, 14 | atlas layers |
| 15, 16 | atlas vertices (count in vertices) |
| 17, 18 | textures |
| 19, 20 | fallbacks |
| 21 | nodes walked |
| 22 | nodes culled |
| 23..34 | prims per feature (index = feature) |
| 35..46 | fallbacks per reason (index = reason) |
| 47, 48 | glyph uploads |
| 49, 50 | glyph draws |
| 51 | glyph masks cached in the glyph atlas |
| 52 | text styles drawn as paths this frame because the frame's budget of new glyph masks ran out (the host draws another frame) |
| 53, 54 | surfaces |
| 55, 56 | effect passes |
| 57 | apron (device pixels around the view) |
| 58 | pixels of every surface this frame |

## Prim (16 words)

A quad over its pixels. Colour = paint; coverage = shape × (shape2, kept or cut out) ×
every clip of the chain × the mask paint × opacity; premultiplied, source-over unless a
blend says otherwise.

| Word | Field |
|---|---|
| 0..3 | `x0, y0, x1, y1` f32: the quad in viewport pixels |
| 4 | `shape` (none: full coverage) |
| 5 | `shape2` |
| 6 | `clip`: the chain's first shape (none: unclipped) |
| 7 | `paint` |
| 8 | `op`: 0 none, 1 times shape2's coverage, 2 times one minus it |
| 9, 10 | `ox, oy` i32 |
| 11 | feature: 1 fill formula, 2 fill path, 3 stroke ring, 4 stroke path, 5 text, 6 fallback, 7 layer (a surface composited), 8 shadow by formula, 9 shadow from a surface |
| 12 | opacity f32 (node opacity × paint opacity) |
| 13 | bits 0..7 blend: 0 source-over, 1..17 `pix.BlendMode` (multiply … luminosity, the CPU's `blendPixel`), 31 lerp (the target moves toward the paint by the coverage: a background blur); bits 8..15 mask mode: 0 none, 1 alpha, 2 luminance, 3 one minus alpha |
| 14 | mask paint (none: none) |
| 15 | unused |

"None" is `0xffffffff` everywhere.

## Shape (32 words)

| Word | Field |
|---|---|
| 0 | kind: 1 rectangle, 2 ellipse, 3 atlas |
| 1 | `next`: the next clip of a chain |
| 2 | atlas layer |
| 3 | flags: bit 0, `inner` is a hole (the ring) |
| 4..7 | `a, b, c, d`: top space to the shape's space (`x' = a x + c y + e`) |
| 8..11 | `e, f`, unused, unused |
| 12..15 | `outer`: x0, y0, x1, y1 in the shape's space (atlas: the entry's pixels, top space) |
| 16..19 | corner radii top left, top right, bottom right, bottom left (atlas: the texel of the entry's top left pixel, x, y) |
| 20..23 | `inner` (the hole) |
| 24..27 | its radii |
| 28..31 | unused |

Formula shapes: inside is `x0 <= x < x1` and `y0 <= y < y1` (the CPU's crossing rule)
with circular corners; the ring is the even-odd of `outer` and `inner`. An upright,
evenly scaled shape is given in top space (its matrix the identity, its edges the
CPU's numbers); others in node space with the inverse matrix. Atlas shapes cover pixel
`p` by the mean of texels `(ax, ay) + 2 (p - (x0, y0)) + {0, 1}²` of their layer.

## Paint (16 words)

| Word | Field |
|---|---|
| 0 | kind: 1 solid, 2 linear, 3 radial, 4 angular, 5 diamond, 6 image, 7 surface or CPU layer, 8 shadow, 9 shadow by formula |
| 1 | flags: images bit 0 tile, bit 1 decal; surfaces bit 0 filtered (bilinear); formula bit 0 ellipse, bit 1 inner |
| 2 | gradients: first stop (vec4 index); images: texture; surfaces and shadows: the surface |
| 3 | gradients: stop count; images: mip levels |
| 4..7 | solid: premultiplied colour |
| 8..11 | `a, b, c, d`: top space to the paint's space (gradient space, image pixels, layer texels) |
| 12..15 | `e, f`; images: the width and height of level 0 |

Gradients take `t` from the paint space point as `pixmap.Gradient` does and interpolate
straight colour and alpha apart, then premultiply. A shadow (8) is `colour` times the
surface's alpha bilinear at `inv(centre) - 0.5` (a drop shadow's offset, whole and
fractional, is in `inv`, as `sampleShift` takes it). A shadow by formula (9) is `colour`
times the box `inv` (x0, y0, x1, y1, top space; offset and spread applied) with corner
radii `inv_t`, or the ellipse in it, blurred by a Gaussian of sigma `b` (f32 bits): exact
for a plain box (a product of two `erf` integrals), otherwise each row's exact integral
summed across rows; inner shadows take one minus it. Images sample as `pixmap.ImageShader`:
the level from the footprint (`sqrt |det|`), bilinear in each level, linear between two.

## Stops

Two vec4 per stop: `(offset, 0, 0, 0)`, then the straight colour, quantised as
`colour.stop` says.

## Draw (8 words)

`kind, first, count, tex, mask, flags`, 2 unused.

- Kind 0: prims `first .. first + count`, one instanced draw. `tex`: the texture their
  paints read (an image index, or `0x80000000 | surface`; none: none); `mask`: the one
  their mask paints read. Flags bit 0: blended (one prim; the host copies the target's
  pixels under it first and the prim writes the blend's result); bit 1: composite by
  maximum (a silhouette grown by a shape); bit 2: erase (the target times one minus the
  prim's alpha).
- Kind 1: fallback `tex` goes here; `first` is its prim, which carries the clip and the
  offset and is not drawn itself.
- Kind 2: later draws go to surface `first`, cleared, until kind 3 with the same `first`
  returns to the target before it.
- Kind 4: effect pass `first` runs here.

## Surface (16 words)

`w, h, x0, y0` (i32: the space's pixel at texel 0, 0), `flags` (bit 0: its pixels depend
on its own draws alone), `key_lo, key_hi` (the node, part, matrix and rect it draws, and the node's subtree
revision, so an edit under it gives it a new key),
`base` (the node and part alone), `end` (the index of its kind 3 draw), the node's matrix
(6 f32), unused. A host may keep a surface's pixels for later frames under its key and
skip its draws while kept; the engine marks one holding a CPU layer or reading what lies
under it as not to be kept.

## Effect pass (32 words)

`kind, src, dst`, unused, `i` (8 i32), `f` (20 f32): the CPU's numbers, run on surface
`dst` (rows, then columns, through a second texture):

| Kind | Does | Parameters |
|---|---|---|
| 1 | Gaussian, cut at `i[0]` texels, normalised over the whole kernel; outside clear | `f[0]` sigma |
| 2 | three box blurs (`pixmap.blurAlpha` past sigma 24) | `i[0..3]` half widths |
| 3 | progressive blur, sigma per pixel (`effects.progressiveBlur`) | `f[0..6]` device to node, `f[6..8]` start, `f[8..10]` run, `f[10]` its length squared, `f[11..13]` sigmas, `f[13]` kernel reach |
| 4 | spread (`pixmap.spreadAlpha`): square max (`i[1]` 1) or min by `i[0]` + `f[0]` | |
| 5 | noise (`effects.drawNoise`), from `src` | `f`: device to node, cell, density, colours, opacity, density k, edge; `i[0]` type, `i[1]` samples a side |
| 6 | texture (`effects.drawTexture`), from `src` | `f`: device to node, the matrix, cell, amplitude; `i[0]` clip |
| 7 | the target's pixels (before `dst`'s begin) into `dst`, mirrored at `i[0..4]` (top space) when `i[6]`; target texel = top + `i[4..6]` | |

## Path atlas

Layers of 2048 x 2048 texels, two per device pixel each way. Paths are cut into cells
of 1016 device pixels (in top space); each cell in view is an entry.

- Entry (8 words): `layer, rule (0 nonzero, 1 even-odd), x, y, w, h` (the entry with 4
  texels of padding: what the cover pass covers), 2 unused.
- Layer (8 words): `vert_first, vert_count, entry_first, entry_count, glyph_first,
  glyph_count`, 2 unused.
- Vertices: two f32 each, layer texels, a triangle list: each contour as a fan from its
  first point, cut to a pixel around its entry.

Per layer: one render pass with a 4x multisampled `r8unorm` colour and `stencil8`, the
fans counting the winding into the stencil (front faces up, back faces down, wrapping),
then a quad per entry where the stencil says inside (nonzero: any; even-odd: the low bit)
writing 1 and zeroing the stencil, resolved into the layer. The standard 4x positions at
twice the resolution are Figma's 16 points. Then the layer's glyph draws are added in
(blend one + one).

## Text

Each text style is one atlas path, as the CPU fills each style's glyphs as one path.
Upright text up to 128 device pixels per em fills its entries from the glyph atlas
instead; larger or turned text, and anything the glyph atlas has no room for that frame,
goes through stencil and cover as glyph outlines. Decorations are always paths.

The glyph atlas (4096 x 4096 `r8unorm`, one texel per device pixel) holds each glyph
rasterised by the CPU's sampled rasteriser at its size and sub-pixel position (the key:
font, glyph, scale, and the origin's fraction of a pixel, exactly), so a mask is the
CPU's coverage of that glyph. It is kept between frames (panning by whole pixels reuses
every mask) and starts over when full, unless the last frame's masks took most of it (then text without masks draws as paths). A frame rasterises at most `glyph_budget` new
masks (400): a style needing more than is left draws as paths that frame (one needing more than a whole budget takes it whole when it comes first), so zooming (every glyph new
at every scale) costs no more than the paths, and the masks fill in over the next frames.

Every frame the engine builds must be encoded: its new masks are in the engine's glyph
map from then on, so the host uploads them even when it does not draw the frame.

- Glyph upload (8 words): `x, y, w, h, ptr`, 3 unused: `w * h` coverage bytes for the
  glyph atlas at (`x`, `y`). Only masks new this frame.
- Glyph draw (8 words): `layer, dx, dy, w, h, sx, sy`, 1 unused: the mask's `w` x `h`
  texels at (`sx`, `sy`) added into layer texels from (`dx`, `dy`), each over 2x2. The
  sum is the CPU's union of the style's glyphs wherever glyphs do not overlap.

## Texture (8 words)

`hash_ptr, hash_len, width, height, levels`, 3 unused: an image asset, its level 0 size
and mip count; its pixels from `pe_gpu_texture_level`.

## Fallback (24 words)

What the GPU does not draw, drawn by the CPU and composited in its place: since layout 3
only text with glyph origins snapped to a device grid (`glyph_x_bins`, a matching tool's
setting); the other parts and reasons stay for the CPU layers' sake.

| Word | Field |
|---|---|
| 0, 1 | node id: address, length |
| 2 | part: 0 the node, 1 its drop shadows, 2 its inner shadows, 3 a mask run |
| 3 | mask run: the mask's index among the node's children |
| 4 | reason: 1 text (snapped glyphs), 2 effect, 3 blend mode, 4 opacity, 5 pattern, 6 paint blend mode, 7 clip path, 8 drop shadow, 9 inner shadow, 10 mask |
| 5 | its prim |
| 6 | `rev`: the node's subtree revision (an edit gives its layers new keys) |
| 7 | unused |
| 8..13 | the node's matrix to top space, f32 |
| 14, 15 | unused |
| 16..19 | where it shows: x0, y0, x1, y1 i32, top space |
| 20..23 | everything it may paint, i32, top space |

The host cuts layers from the second rect in 512-pixel tiles (only those meeting the
first), keyed by node, part and matrix, and draws each with a prim copied from the
fallback's.

## Surfaces: what the walk puts in them

The walk mirrors `Renderer.drawIsolated` and friends with surfaces where the CPU has
pixmaps: a node with opacity, a blend mode, noise, texture or a blur draws its content
into a surface over the CPU's layer rect, runs its passes, and composites it (with its
blend mode through the backdrop copy). Drop shadows of rectangles and ellipses whose
silhouette is their shape draw by formula; others cast from the shape's coverage or the
node's surface (opaque paints for its silhouette when some are see-through): a surface of
the source's alpha, spread (by shape: the grown shape by maximum) and blurred, composited
with the offset and knocked out by the source. Inner shadows: a surface of the shape's
outside moved by the offset (white, the moved shape erased), spread and blurred, kept
inside the shape. Background blurs: the target's pixels mirrored at the node's bounds into
a surface, blurred, then the node's shape moves the target to them (lerp). Masks: the
mask's coverage (shape, alpha or luminance) and the masked siblings in surfaces, one
through the other. Patterns: the source tiled into a surface over the fill (or stroke),
composited through it. A clip over several atlas cells: its children in a surface
composited through each cell's shape. Blurs wider than `coarse_sigma` draw on the coarse
grid as the CPU does.

## Motion

While the host says the view is moving (`pe_gpu_motion`), glyph masks come from scale
buckets (eight an octave; the origin's fraction in quarters above 24 pixels an em, else none; the nearest bucket cached
within one bucket, or up to eight for text under two pixels an em) and a node part's polylines from
the last exact ones of a scale within a quarter to four times this one, moved there. The host draws
an exact frame once the view settles; surfaces and checks always draw exact.

## Edits

An edit (`src/edit/editor.zig`) bumps the changed nodes' revisions (`rev`, and `tree_rev`
on them and their ancestors) and names the node pointers whose kept data is stale:
changed, moved by a new list of siblings, or removed. The next frame drops the paths,
text layouts, polylines and stand-ins kept of those nodes, and what is known about their
subtrees reading the backdrop; everything else stays. Surface keys and CPU layer keys carry
the subtree revision, so a host's kept surfaces of an edited subtree miss and age out
under the cap; nothing is cleared. A pattern's surface also carries its source's revision.


# Records (the canvas's default since 2026-10-17)

The page as records kept on the GPU (`src/gpu/records.zig`; host `editor/viewer/records.ts`
and `items.ts`): written once per page in each top-level node's own units, so a frame only
says where each top-level node is. `?gpu=immediate` draws the frames above instead.

Each page kept has a builder of its own (the host's `Engine` holds one per page): its
lists stay in the engine and on the GPU while the page is kept, so showing it again is a
frame. A builder points into its page's nodes: it goes before its page does
(`Engine.unloadPage`).

## Calls (wasm)

| Call | Does |
|---|---|
| `pe_rec_new()` | a records builder (keeps text layouts, paths and glyph outlines between builds) |
| `pe_rec_build(r, s, page)` | writes page `page`'s records; answers the header's address |
| `pe_rec_begin(r, s, page)`, `pe_rec_step(r, s, count)` | the same a few top-level nodes a call: `step` answers 1 while some are left, then the header's address (a list of top-level nodes changed meanwhile starts again) |
| `pe_rec_free(r)` | gives a builder back (its page is no longer kept) |
| `pe_rec_update(r, s, page)` | after edits: the top-level nodes whose subtree revision moved written again at the ends of the lists (`full` 0), or the page written whole (`full` 1: another page, a new list of top-level nodes, more than half of the lists unread), or nothing (`full` 2) |
| `pe_rec_frame(r, s, x, y, scale, w, h)` | a frame's cameras, the top-level nodes and items in view; asks the session for the images in view at the detail drawn |
| `pe_rec_item(r, sc, s, item, w, h, margin, max_px)` | item `item` drawn by the frame builder `sc` at the last frame's camera (its rect, matrix and the scene's header) |
| `pe_rec_held(r, s, image)`, `pe_rec_level(r, s, image, level)` | what an image's chain holds now, and a level's pixels |
| `pe_rec_shader()` | the WGSL (`common.wgsl`, `curves.wgsl`, `records.wgsl`) |
| `pe_rec_forget(r)` | drops what is kept between builds (fonts or the document changed) |

## Coordinates

Every record belongs to a top-level node and names its node's matrix to that node (the
transform table, `xf`). A frame's camera for a top-level node is `Session.place`: the
matrix to its top space and the whole-pixel offset of top space in the target. The
shaders compose camera and node matrix (`Affine.mul`) into the CPU's `ctm`, and number
pixels in top space, so coverage is taken at the CPU's sample points and panning by whole
pixels changes no number.

## Lists

All little-endian 32-bit words; the header (45 words) gives each list's address and count
in this order: prims, shapes, paints, stops, xforms, curves, paths, bands, band items,
draws, tops, images, masks, items, then `full`, nodes, glyphs, approximated and prims per
feature.

- **Prim** (16 words): `x0, y0, x1, y1` (where it may paint, top-level units), `shape,
  shape2, clip, paint, op, xf, top, feature`, opacity, blend, `owner` (the item it stands in
  for: hidden while that item, or one around it, has a picture), `margin` (device pixels the
  quad reaches past its rect).
- **Shape** (32 words): `kind` (1 rectangle, 2 ellipse, 3 path, 4 glyph), `next` (clip
  chain), `xf`, flags (bit 0 ring, bit 1 even-odd), then node-space numbers: rectangles and
  ellipses the box, radii, hole and its radii; a path its path record; a glyph its path
  record and its glyph matrix (font units to node space). `v6` holds its bounds.
- **Paint** (16 words): as above, with node-space matrices (node to gradient space, node to
  the image's full-size pixels); the shader puts the inverse `ctm` after them. A shadow by
  formula is two records: the box, radii and colour (node units), then offset, radius,
  spread and `shadow_k`. Kind 10 composites item `a`.
- **Xform** (8 words): the node's matrix to its top-level node.
- **Curve** (8 words): a cubic's four points, or a line from p0 to p3 (p1 NaN). Each contour
  ends with its closing line, as the CPU fills it. Glyph curves are in font units, once per
  font and glyph.
- **Path** (8 words): `curve_first, curve_count, band_first, band_count, y0, y1, mask`. Band
  k lists the curves whose control points reach `y0 + k (y1 - y0) / band_count` onward
  (about four curves a band, fewer bands while curves span many).
- **Mask** (8 words): a path of 1,000 curves or more: its coverage over its bounds in a layer
  of 2048² texels (16 samples a texel, levels averaged down; 16 a page at most), read wherever a device pixel
  spans a texel or more.
- **Draw** (8 words): `kind, first, count, tex, flags, top`: prims of one top-level node with
  the image they read.
- **Top** (8 words): its draws, its prims, where it may paint (page units).
- **Item** (12 words): `kind, top, xf, parent, x0, y0, x1, y1, key_lo, key_hi, prim`. Kinds:
  1 a node through layers of its own (group opacity, layer effects, patterns, a backdrop
  read inside it), 2 its drop shadows only, 3 its inner shadows only, 4 a mask run, 5 a
  background blur (what the frame drew under the node, blurred, taken from the target where
  its composite is drawn), 6 a node with a blend mode (drawn by the frame builder onto the
  target in place, every frame). `top` is `none` for an item an update retired.

## Coverage

`curves.wgsl`: each curve through the node's (and a glyph's) matrices to device space,
flattened by Wang's formula with the CPU's tolerance (the same points, `Path.flatten`);
the winding at the 16 sample points counts each segment a sample's row crosses at or left of
the sample, spanning `[min y, max y)`. Upright paths read only the bands of the pixel's rows;
long monotone cubics find the rows' segments by bisection. A masked path drawn no larger
than its mask reads the mask.

## Items

A node the CPU draws through layers of its own is an item: the frame builder above
(`Scene.buildItem`) draws it alone at a frame's exact matrix into a picture kept in an
atlas (`items.ts`), and a prim of paint kind 10 composites it through its clip chain. The
picture is exact when its matrix is the frame's; while the zoom moves, the nearest kept
one stands in (shadows, blurs), or the node's own plain prims (groups and masks, sharp at
any scale). Pictures are drawn a few ms a frame, nearest the centre first; items under
32x32 pixels with a stand-in wait until the view rests, under 16 pixels² never.
Background blurs are taken once every other item is in, and again whenever an item's
picture or an image changed what they read.
