# Pubd 1

The PublrDesign document format. Draft 0, 2026-10-14: enough for the first corpus file
(`engine/corpus/landing`). Draft 1, 2026-10-15: component sets, component properties,
bindings and overrides (below, "Components"). Draft 2, 2026-10-17: variables, their
collections and modes, and fields bound to them ("Variables"). Every later draft adds; a
reader of draft N
opens every file of an earlier draft. Writers write the newest draft they know.

## The file

A `.pubd` file is a zip archive:

```
document.json        the document (this spec)
pages/<name>.json    each page's nodes, when the document is kept page by page (below)
assets/<sha256>      every binary the document uses (images, later fonts), named by the
                     SHA-256 of its bytes, lowercase hex, no extension
```

During development the same layout may sit unzipped in a folder; readers take both.
Writers deflate the zip's JSON entries. A browser keeps a document's JSON files
gzip-compressed in its storage; readers there know gzip by its first two bytes
(`1f 8b`). JSON is written without whitespace.

### Kept page by page

A document of any size opens by reading `document.json` alone; each page's nodes are in a
file of their own, read when the page is shown and given back when another is; an asset
is read when something on screen draws it. `document.json` then holds what a viewer
needs before any page: the name, each page's own fields (no `children`) with `src` (its
file, a path beside `document.json`) and `frames` (its top-level nodes' boxes, for the
page list and fitting the view), the styles, the assets, the nodes pages share
(`shared`), every component and component set (`components`), the glyph outlines (`glyphs`) and the fonts the texts ask for (`fonts`).

```json
{
  "pubd": 0,
  "name": "2024 Caraway Month",
  "pages": [
    { "id": "41:8905", "type": "page", "name": "Cover", "background": "#f5f5f5",
      "src": "pages/41-8905.json",
      "frames": [ { "id": "65:9568", "name": "Cover", "type": "frame",
                    "box": [4160, 13156, 6080, 14236], "bounds": [4157, 13153, 6083, 14239] } ] }
  ],
  "shared": [ Node, ... ],
  "components": { "1393:7528": { "type": "component-set", "name": "Pricing page header",
                                 "page": "708:20673", "properties": [ ... ] } },
  "glyphs": [ "M0.479 0.561C0.479 …Z", ... ],
  "fonts": [ { "family": "Moderat", "style": "Bold", "weight": 700 } ],
  "styles": { ... },
  "assets": { ... }
}
```

- A page file is the page's node, as in a document in one file: its own fields and its
  `children`. Its name is free; writers use the page id with `:` and `;` as `-`.
- `frames[]`: `{ id, name, type, box, bounds }`; `box` is the node's box on the page
  (x0, y0, x1, y1), `bounds` everything it may paint (effects included).
- `shared`: nodes a page draws from that live on another page (a pattern paint's
  `source`), so a page never needs another page's file. A page's own nodes win over a
  shared copy of the same id.
- `components`: every component and component set of the document, by id:
  `{ "type": "component" | "component-set", "name", "page": "<page id>", "set"?: "<set
  id>", "properties"?: [...] }` (`properties` as on the node, "Components" below). An
  instance on one page knows its main (its name, its set, the properties it offers) before
  the main's page is read. Writers list every component on every page, refreshed from
  each page they write; readers trust a page's own nodes over the list.
- A document is kept page by page when every page has `src`; otherwise every page's
  nodes are in `document.json` (the earlier form, still read and written).
A binary form of `document.json` comes later; it will carry the same model.

## Conventions

- Numbers are finite: `nan`, `inf` (not JSON anyway) and numbers too large for a 32-bit
  float are refused by readers; writers never write them.

- Units are CSS pixels at 1x. Numbers are JSON numbers (read as `f64`, stored as `f32`).
- Colours are sRGB, either `"#rrggbb"` / `"#rrggbbaa"` or an array `[r, g, b]` /
  `[r, g, b, a]` of numbers 0..1 (alpha defaults to 1). Arrays keep a colour at full
  precision: writers spell each channel in the shortest digits that read back to the same
  32-bit float, and use hex only when every channel is exactly a byte over 255. Readers
  take both. Files keep values as authored; how a colour becomes 8-bit (or any other)
  output is the renderer's decision, never the file's.
- A transform is `[a, b, c, d, e, f]`, the matrix `x' = a*x + c*y + e`,
  `y' = b*x + d*y + f` (SVG's `matrix()` order), from the node's own space into its
  parent's.
- A field left out takes its default. Writers leave defaults out.
- Unknown fields are kept by every tool that rewrites a file, and ignored otherwise.

## The document

```json
{
  "pubd": 0,
  "name": "Landing page",
  "pages": [ Node, ... ],
  "styles": { "<id>": Style, ... },
  "collections": { "<id>": Collection, ... },
  "variables": { "<id>": Variable, ... },
  "assets": { "<sha256>": { "type": "image/png", "width": 1200, "height": 800 } }
}
```

`collections` and `variables` (draft 2) are in `document.json` also when the document is
kept page by page: every page resolves against them. Their order is the order editors list
them in.

## Nodes

Every node:

| Field | Type | Default | |
|---|---|---|---|
| `id` | string | required | unique in the document |
| `type` | string | required | `page`, `frame`, `group`, `component`, `component-set`, `instance`, `rectangle`, `ellipse`, `line`, `vector`, `text` |
| `name` | string | `""` | the layer name |
| `visible` | bool | `true` | |
| `locked` | bool | `false` | |
| `transform` | transform | identity | not on `page` |
| `size` | `[w, h]` | `[0, 0]` | not on `page`; on a `group`, its bounds as last laid out |
| `opacity` | number | `1` | |
| `blend` | string | `"pass-through"` | `pass-through`, `normal`, and the CSS blend mode names |
| `fills` | Paint[] | `[]` | drawn first to last |
| `strokes` | Paint[] | `[]` | |
| `stroke` | Stroke | see Stroke | how strokes are drawn |
| `effects` | Effect[] | `[]` | |
| `styles` | `{ "fill"?, "stroke"?, "effect"?, "text"?, "grid"? }` | `{}` | style ids this node follows |
| `data` | `{ "<namespace>": any }` | `{}` | host data (bindings); tools keep it, never read it |
| `children` | Node[] | `[]` | `page`, `frame`, `group`, `component`, `instance` only; first is bottom-most |

`page` adds `background` (colour) and `edits` (a whole number, default 0: the changes
the page has had, so a tool holding later changes knows which of them a file it reads
already holds). `group` has no fills, strokes or size of its own: its
size is its children's bounds.

### Containers: `frame`, `component`, `component-set`, `instance`

| Field | Type | Default |
|---|---|---|
| `radius` | number or `[tl, tr, br, bl]` | `0` |
| `smoothing` | number 0..1 | `0` |
| `clip` | bool | `false` |
| `layout` | Layout | none |
| `grids` | Grid[] | `[]` (drawn in the editor only) |

`instance` adds `component` (the main component's id, left out when the main is not in the
document). An instance's `children` are its full resolved content, which a file may
hold as changes to a copy instead ("Instances in files"); what it overrides is recorded
in `overrides` (draft 1, "Components").

### Shapes

- `rectangle`: `radius`, `smoothing` as above.
- `line`: from (0, 0) to (width, 0); height 0. Strokes only: `inside` draws above the line,
  `outside` below, `center` across it.
- `ellipse`: `arc` `{ "start": rad, "end": rad, "inner": 0..1 }`, default a full ellipse.
- `vector`: `network`, Figma-style vector network in the node's own space:
  ```json
  { "vertices": [[x, y], ...],
    "segments": [{ "from": 0, "to": 1, "t0": [dx, dy], "t1": [dx, dy] }, ...],
    "regions":  [{ "winding": "nonzero", "loops": [[0, 1, 2, 3]] }] }
  ```
  `t0`/`t1` are the tangents at `from`/`to`, relative to their vertex (`[0, 0]` = straight).
  Regions are filled; every segment is stroked.

- `star`: `count` points, `innerScale` (inner radius over outer). `polygon`: `count` sides.
- `boolean`: `op` `union` | `intersect` | `subtract` | `exclude` of its `children`, which it
  does not draw itself.
- `slice`: an export area; never drawn.
- `geometry` (vectors, stars, polygons, booleans): `[{ "winding", "d", "fills"? }]`, the
  resolved fill outline in node space (SVG path data); a path's own `fills` replace the
  node's for that region. Kept like resolved positions; tools recompute it on edits.

Any node may take `mask`: `alpha` | `vector` | `luminance`. A mask is not drawn; it masks
the siblings after it, up to the next mask: by its alpha, its shape, or its luminance
times alpha. A container with `reverseZ` stacks its children in reverse (first on top).

A `group` may `repeat` its children: `{ "type": "linear" | "radial", "count": 6, "offset":
48, "vertical": false }`. Linear copies move by `offset` along x (or y); radial copies turn
by 360°/`count` about the group's centre (`offset` is the diameter they sit on).

### Text

| Field | Type | Default |
|---|---|---|
| `text` | string | `""` |
| `style` | TextStyle | see below |
| `runs` | `[{ "from": n, "to": n, "style": TextStyle-part, "fills"?: Paint[] }]` | `[]` |
| `resize` | `fixed`, `height`, `width-and-height`, `truncate` | `fixed` |
| `align` | `left`, `center`, `right`, `justify` | `left` |
| `valign` | `top`, `center`, `bottom` | `top` |
| `skipInk` | bool: underlines leave gaps where glyphs cross them | `true` |
| `truncation` | `none`, `ending` (the last line that fits ends in an ellipsis) | `none` |
| `maxLines` | lines shown at most when truncating; absent: as many as fit the box | absent |
| `wrap` | `auto`, `balance` (a paragraph's lines made as even as its line count allows), `pretty` | `auto` |
| `leadingTrim` | `none`, `cap-height` (the box starts at the first line's cap height and ends at the last baseline) | `none` |
| `hangingPunctuation` | punctuation that starts a line hangs outside the box | `false` |
| `hangingList` | list markers hang outside the box instead of indenting the text | `false` |
| `lists` | `[{ "type": "none" \| "ordered" \| "unordered", "indent": n }]`, one per paragraph in order; paragraphs past the end are plain | `[]` |
| `pathStart` | `{ "segment": n, "position": n }`: where text on a path starts | `{ "segment": 0, "position": 0 }` |
| `glyphs` | the text as its source laid it out: `[[outline, x, y, size, char(, rotation)], ...]` | `[]` |
| `glyphRects` | its underlines and strikethroughs as laid out: `[[x, y, w, h, char], ...]` | `[]` |

`glyphs` and `glyphRects` are a cache, like a vector's `geometry`: how the tool the text
came from drew it (Figma's `derivedTextData`). Each glyph is outline `outline` (an index
into the document's `glyphs`: SVG path data in ems, y up) drawn `size` big with its origin
at `x`, `y` (node space, on the baseline), turned by `rotation` radians; `char` is the
UTF-16 index of the first character it draws, whose run gives its paints (else the node's
fills). A viewer draws them instead of laying the text out while a font the text asks
for is missing, so the text looks as it did where it was made; with every font present
the text is laid out from its fields. A tool that changes the text drops both.

Run offsets count UTF-16 code units of `text`. A text node that has a `network` is text
on a path: one line laid along the network's segments from `pathStart`, its baseline on
the path. TextStyle:

| Field | Default |
|---|---|
| `family` | required |
| `weight` | `400` |
| `italic` | `false` |
| `fontStyle` | `"Regular"` (the face name, for exact matching) |
| `size` | `16` |
| `lineHeight` | `"auto"`, or `{ "px": n }`, or `{ "percent": n }` |
| `letterSpacing` | `0` (px), or `{ "percent": n }` |
| `paragraphSpacing` | `0` |
| `paragraphIndent` | `0` (extra indentation of each paragraph's first line) |
| `case` | `none`, `upper`, `lower`, `title`, `small-caps`, `small-caps-forced` |
| `decoration` | `none`, `underline`, `strikethrough` |
| `decorationStyle` | `solid`, `dotted`, `wavy`: how the decoration line is drawn (default `solid`) |

## Components

A `component` is a main component; a `component-set` holds the variants of one component
side by side (each a `component` child named by its values, `"Size=Large, State=Hover"`)
and draws as a frame. An `instance` shows its main component (`component`): its
`children` are copies of the main's, resolved (every field as it shows).

**Ids.** A copy's id is `I<instance id>;<path>`: the path of the node it copies inside
the main, where a copy inside a nested instance adds that instance's path
(`I<outer>;<nested instance>;<node>`), as Figma's REST API names them. The path is what
`overrides` and `props` refer to.

| Field | On | Type | |
|---|---|---|---|
| `properties` | `component`, `component-set` | `[{ "id", "name", "type", "default", "options"? }]` | the properties instances may set; `type` is `boolean`, `text`, `instance-swap` or `variant`; `default` the value an instance has unless it sets one (`true`, `"Label"`, a component id, a variant value); `options` a variant's values, or the components preferred for a swap |
| `bind` | a node inside a main | `{ "visible"?, "text"?, "component"? }` | the property (by id) that drives the node's visibility, its characters, or (a nested instance) its component |
| `props` | `instance` | `{ "<property id>": value }` | the values the instance gives its main's properties; a variant property's id is its name |
| `overrides` | `instance` | `{ "<path>": ["<key>", ...] }` | the Pubd keys each node below the instance sets itself (`""` the instance itself); the values are the nodes' own |

An instance with `overrides` follows its main for every key not listed: when the main
changes, a tool copies the change into each instance and leaves overridden keys alone.
Overrides belong to the outermost instance: a nested instance's copies are listed on the
instance that contains them, by their path below it. An instance without `overrides`
(draft 0) has them worked out by comparing it with its main.

### Instances in files

Most of a design is instances, and instances of one component hold nearly the same
content. A page therefore keeps one copy of each component's content, and its instances
are written as their changes to it; a reader puts their `children` back before anything
else reads the page.

- `bases` (on a `page`): `{ "<component id>": [ Node, ... ] }`, the content of one
  instance of that component, with ids relative to it (an instance's prefix
  `I<instance id>;` left off; an instance whose own id starts with `I` has the prefix
  `<id>;`). Instances inside a copy may be written as changes in turn.
- `changes` (on an `instance`, instead of `children`): `{ "<path>": { "<key>": value,
  ... }, ... }`. The instance's content is its component's copy with ids under its
  prefix, every instance inside it given its content the same way, then for each path
  (an id less the prefix) each key set to its value, or removed when the value is `null`.
  `"children"` replaces a node's content with the nodes given (ids relative, as in
  `bases`); the path `""` replaces the instance's whole content. `{}` means the content is
  the copy as it is.

A page read in pieces reads `bases` from its file less its top-level nodes, then each
top-level node against them. Writers keep `bases` on the page and may write any
instance whole.

## Paint

```json
{ "type": "solid", "color": "#2947a9" }
{ "type": "linear" | "radial" | "angular" | "diamond",
  "stops": [{ "at": 0, "color": "#000000" }, ...],
  "handles": [[x, y], [x, y], [x, y]] }
{ "type": "image", "asset": "<sha256>", "scale": "fill" | "fit" | "crop" | "tile" | "stretch",
  "transform": transform, "tile": 1 }
```

{ "type": "pattern", "source": "<node id>", "tiles": "rectangular" | "horizontal-hexagonal"
  | "vertical-hexagonal", "scale": 1, "spacing": [x, y], "align": ["start" | "center" | "end",
  "start" | "center" | "end"] }
```

A pattern tiles the source node (drawn as it is, at `scale`) with `spacing` between tiles,
counted in tile sizes (1 leaves a gap one tile wide);
hexagonal tiling shifts every other row (or column) by half a tile. `align` places the grid
against the filled box horizontally and vertically: `center` puts a tile's centre on the
box's centre. Only frames, components and instances work as sources.

Every paint also takes `visible` (default `true`), `opacity` (default `1`) and `blend`
(default `normal`). Gradient handles are in the node's unit square (0..1 on both axes):
start, end, and the width handle. An image `transform` maps the node's unit square onto
the image's, for `crop` and `stretch`.

## Stroke

`{ "weight": 1, "align": "center" | "inside" | "outside", "cap": "none", "join": "miter",
"miter": 4, "dashes": [] , "sides": [t, r, b, l] }`. Defaults as shown, `align` `inside`
for containers and rectangles, `center` otherwise. `sides` only on rectangles and
containers.

`outline` (optional): `[{ "winding": "nonzero" | "evenodd", "d": "M0 0L10 0..." }]`, the
resolved stroke shape in node space as SVG path data (M, L, C, Q, Z). Kept like resolved
positions, so a reader can draw strokes it cannot compute itself (variable widths,
brushes); tools recompute it when the stroke changes. Inside and outside strokes are still
clipped by the fill.

What makes a stroke more than its weight (all optional; `outline` holds their result):

- `widths`: `[{ "segment": 0, "at": 0.5, "ascent": 0.5, "descent": 0.5 }]`, a
  variable-width stroke: at `at` (0..1) along segment `segment` of the path, the stroke
  reaches `ascent` to one side and `descent` to the other, as fractions of `weight`
  (0.5 each is the plain width); between points the width runs smoothly.
- `brush`: `{ "type": "stretch" | "scatter", "name": "Bubblegum", "size": [w, h],
  "geometry": [{ "winding"?, "d" }], "reverse"?: false, "scatter"?: Scatter,
  "adjust"?: Scatter, "stamps"?: [transform, ...] }`: a brush shape (its own space, `size`
  big) laid along the path. `stretch` bends one copy along the whole path (`reverse`:
  backwards); `scatter` stamps copies, placed by `stamps` (brush space to node space, as
  resolved, full precision). Scatter is `{ "gap", "wiggle", "angleJitter", "rotation",
  "sizeJitter" }`: `scatter` the brush's own, `adjust` the node's settings on top of it.
- `dynamic`: `{ "frequency": 5, "wiggle": 8, "smoothen": 0.5 }`, a hand-drawn wobble of
  the path.

## Effect

```json
{ "type": "drop-shadow" | "inner-shadow", "color": "#00000040", "offset": [x, y],
  "radius": 4, "spread": 0, "behind": false, "blend": "normal", "visible": true }
{ "type": "layer-blur" | "background-blur", "radius": 4, "visible": true,
  "progressive"?: { "start": [x, y], "end": [x, y], "startRadius": 0 } }
{ "type": "noise", "noise": "monotone" | "duotone" | "multitone", "color": "#1a1c20a6",
  "secondary"?: "#2454f4", "opacity"?: 1, "grain": [x, y], "density": 0.5,
  "radius": 0, "visible": true }
{ "type": "texture", "grain": [x, y], "radius": 5, "clip"?: true, "visible": true }
```

`behind` (drop shadows only): the shadow also shows through transparent parts of the node.
A drop shadow is cast as if the node's paints were opaque (paint opacity and solid colour
alpha are ignored); without `behind` it is knocked out wherever that opaque silhouette is.

`progressive` (blurs): the radius runs linearly from `startRadius` at `start` to `radius`
at `end`, both in the node's box (0..1 on each axis), measured along the line between
them and held beyond either end. Without it the radius is uniform.

`noise`: grain drawn over the node's content, in node space. `grain` is the grain size in
node units (width, height; different values give stretched grain), `density` (0..1) how
much of the node it covers. `monotone` grains take `color`; `duotone` puts `secondary` on
those grains and `color` on as many others; `multitone` gives each grain its own colour at
`opacity`. The grain pattern is the reader's own: only its size, coverage and colours
are defined.

Noise and texture take `seed` (an integer, default 0): the grain's random seed, kept so
a reader that matches the source's grain generator can reproduce it.

`texture`: the node's content displaced by a random field of grain size `grain`, by up to
about `radius` × 0.7 node units, which roughens its edges. With `clip` (the default) the
node keeps its own coverage and only colours inside it move.

## Layout (auto layout)

```json
{ "mode": "horizontal" | "vertical" | "grid", "wrap": false, "gap": 0, "crossGap": 0,
  "padding": [t, r, b, l],
  "main": "start" | "center" | "end" | "space-between" | "space-around" | "space-evenly",
  "cross": "start" | "center" | "end" | "baseline",
  "width": "fixed" | "hug", "height": "fixed" | "hug",
  "alignContent": "auto" | "space-between", "strokesIncluded": false,
  "columns": [Track, ...], "rows": [Track, ...] }
```

`gap` is between children (between columns in a grid), `crossGap` between wrapped lines
(between rows in a grid). `space-between` puts the free space between the children,
`space-around` half a share before the first and after the last, `space-evenly` equal
shares everywhere. `alignContent` spreads wrapped lines over the frame (`space-between`)
or stacks them `crossGap` apart (`auto`). With `strokesIncluded`, strokes take space: a
child's box grows by the part of its stroke outside it.

A grid lays its children in the cells of its tracks. A Track is `{ "type": "fixed" |
"flex" | "hug", "value": n }`: `fixed` is `value` pixels, `flex` a share (`value`, like CSS
`fr`) of what the other tracks and gaps leave, `hug` as big as its largest single-track
child. A grid child takes `cell` `{ "column": 0, "row": 0, "columnSpan": 1, "rowSpan": 1,
"h": "auto" | "start" | "center" | "end", "v": ... }` (0-based; `auto` is the frame's
default, start).

A child of an auto-layout container takes `sizing` `{ "w": "fixed" | "hug" | "fill",
"h": ... }` and `absolute` (bool, out of the flow). Every child of any container takes
`constraints` `{ "h": "left" | "right" | "left-right" | "center" | "scale", "v": "top" |
"bottom" | "top-bottom" | "center" | "scale" }`, default left/top. Any node may take
`minWidth`, `maxWidth`, `minHeight`, `maxHeight` (numbers, absent: no limit), which hug and
fill sizing respect.

An `instance` scaled as a whole takes `scale` (default 1): its content is its component's
at that scale.

Positions in the file are always resolved: a reader can draw a document without running
layout. Tools run layout when something changes (PublrEngine: `engine/docs/layout.md`).

## Grid

`{ "type": "columns" | "rows" | "grid", "count": 12, "gutter": 32, "offset": 112,
"size": 72, "align": "stretch" | "start" | "center" | "end", "color": "#ff000019",
"visible": true }`

## Style

`{ "type": "fill" | "text" | "effect" | "grid", "name": "Primary", "description": "",
"value": ... }`: the value is the paints, text style, effects or grids. A node that
follows a style also stores the resolved value, so a reader never needs the style to draw.

`styles` lists them in the order editors list them. The file's own styles are those with
neither of these: `library: true` with `key` (the library's key for it), a style copied in
from a library, and `deleted: true`, a style removed but kept because layers still follow
it. Both stay so the layers that use them still name them; editors leave them out of the
file's list of styles.

A grid style's value is its grids, as on a node; a `stretch` guide's column size depends
on the frame it is applied to, so in a style it is `0`. A style's value may be absent (a
REST import keeps only what nodes resolve): a tool that needs it reads it from a node that
follows the style.

A style's value may hold bindings like the objects it is made of (a fill style's paint
bound to a colour variable, "Variables"); the value written is the variables' worth in
each collection's default mode, a style belonging to no frame.

## Variables

Draft 2. A **variable** is a named value of one type, with a value per **mode**; it lives
in a **collection**, and the collection's modes are its columns. A node field **bound** to
a variable takes the variable's value in the modes the node is in. Variables follow
Figma's (its Variables help pages and the Plugin API's `Variable`,
`VariableCollection` and `boundVariables`).

**Resolved fallbacks.** Every bound field also holds the value the binding resolved to,
where it always is (a paint's `color`, a frame's `layout.gap`, a text's `style.size`), so
a reader that ignores variables draws the document right. A reader that knows them
resolves each binding on reading and when something changes, and keeps the result in the
field; a writer writes the field as resolved.

### Collection

```json
"collections": {
  "C:1": { "name": "Theme", "modes": [ { "id": "m:light", "name": "Light" },
                                       { "id": "m:dark", "name": "Dark" } ],
           "library": true, "key": "605934f2…", "hidden": false,
           "parent": "C:0", "overrides": { "V:7": { "m:light": "#101010" } } }
}
```

| Field | Default | |
|---|---|---|
| `name` | `""` | |
| `modes` | `[]` | `{ id, name, parent? }` in order; the **first is the default mode** |
| `library` | `false` | copied from a library (another file): its variables are that library's, as of the version the file holds |
| `key` | `""` | the library's key for it (Figma's `key`) |
| `hidden` | `false` | hidden from publishing |
| `deleted` | `false` | removed, kept because layers still use its variables; editors leave it out of lists |
| `parent` | none | an **extended collection**: the collection it extends. It has the parent's variables; each of its modes extends one of the parent's (`modes[].parent`), and `overrides` (variable id to values by its own mode ids) replace the parent's values where it sets them |

### Variable

```json
"variables": {
  "V:1": { "name": "color/surface", "collection": "C:1", "type": "color",
           "values": { "m:light": "#ffffff", "m:dark": { "alias": "V:9" } },
           "description": "Page background", "scopes": ["frame-fill", "shape-fill"],
           "code": { "web": "var(--surface)", "ios": "Color.surface", "android": "surface" },
           "hidden": false, "key": "1cabf927…", "deleted": false }
}
```

| Field | Default | |
|---|---|---|
| `name` | `""` | `/` separates groups (`color/surface`), as Figma groups them |
| `collection` | required | the collection's id |
| `type` | `color` | `color`, `number`, `string`, `boolean` |
| `values` | `{}` | by mode id: a value of the type, or `{ "alias": ref }`, or (colours) `{ "compose": { "color": C, "opacity": N } }` |
| `description` | `""` | |
| `scopes` | `[]` (everywhere) | where editors offer it, Figma's scope names lower case with `-`: `text-content`, `corner-radius`, `width-height`, `gap`, `all-fills`, `frame-fill`, `shape-fill`, `text-fill`, `stroke`, `stroke-float`, `effect-float`, `effect-color`, `opacity`, `font-style`, `font-family`, `font-size`, `line-height`, `letter-spacing`, `paragraph-spacing`, `paragraph-indent`, `font-variations`, `transform`, `color-opacity` |
| `code` | `{}` | code syntax per platform: `web`, `ios`, `android` |
| `hidden` | `false` | hidden from publishing |
| `key` | `""` | the library's key for it |
| `deleted` | `false` | removed, kept because layers still use it |

Values are Pubd values: a colour as everywhere (`"#rrggbb"`, `[r, g, b, a]`), a number, a
string, `true`/`false`. A mode the variable has no value for takes the default mode's.

**References.** A `ref` names a variable by its id. A library variable the file does not
hold (or a version of one it does not) is `"key:<library key>"` (or
`"key:<key>@<version>"`): it does not resolve, and fields bound to it keep their values.

**Aliases** resolve the variable they name in *its own* collection's mode at the node
(an alias across collections follows the node's mode for that collection), to any depth;
a loop resolves to nothing. **Compose** makes a colour whose opacity is a number, both a
value or an alias: `opacity` is in percent; bound to a paint it sets the paint's colour and
its `opacity` (0..1), elsewhere it multiplies the colour's alpha.

**Units.** Numbers bound to `opacity` (a node's or a paint's) are percent (40 is 0.4);
`lineHeight` and `letterSpacing` are pixels; everything else is in the field's own unit.
Inside an instance scaled as a whole (`scale`, the product of every such instance it is
in, its own included) a bound length is the variable times the scale, as the instance
shows it; a text style's sizes are not scaled (the text's layout is).

A `fontStyle` that names the face the field already has, but for case and spacing
("Semibold", "SemiBold"), leaves it as it is.

### Modes on nodes

Any node (a page, a frame, a section, an instance, ...) may set modes for itself and
everything in it:

```json
{ "id": "1:2", "type": "frame", "modes": { "C:1": "m:dark" } }
```

The mode of collection C at a node is the innermost `modes[C]` on the node or an ancestor
(a mode C does not have is skipped), else C's default. A mode of an extended collection E
(`modes[E]`) stands for C = E's parent: values come from E's `overrides`, else from the
parent mode it extends. An instance's copies are inside the instance, so the instance's
modes and its ancestors' hold for them.

### Bindings

An object binds fields with `vars`: `{ "<key>": ref }`, the key naming a field of that
object. A solid paint's colour and a gradient stop's colour bind with `var` (draft 2's
first form, kept).

| Object | Keys |
|---|---|
| node | `visible` (boolean), `opacity`, `width`, `height` (a fixed axis only: one auto layout fills or hugs, or a text fits, is the layout's), `minWidth`, `maxWidth`, `minHeight`, `maxHeight`, `radius` (every corner), `radius/0`..`radius/3` (tl, tr, br, bl), `stroke/weight`, `stroke/sides/0`..`3` (t, r, b, l), `gap`, `crossGap`, `padding/0`..`3` (t, r, b, l), `text` (the characters: a string, or a number written out), `x`, `y` (the transform's translation), `count` (stars, polygons), `props/<property id>` (an instance's component property value: boolean or text) |
| paint | `var` (solid: the colour), `vars.opacity` |
| gradient stop | `var` (the colour) |
| text style (`style`, a run's `style`, a text style's value) | `family`, `fontStyle` (a string: sets `fontStyle`, `weight` and `italic` from the name), `weight`, `size`, `lineHeight`, `letterSpacing`, `paragraphSpacing`, `paragraphIndent` |
| effect | `color`, `radius`, `spread`, `offset/0`, `offset/1`, `grain/0`, `grain/1`, `secondary` |
| grid | `count`, `gutter`, `offset`, `size` (not a `stretch` grid's: that follows the frame) |

Bindings ride with what holds them: a node that follows a style holds the style's paints
with their `var`; an instance's copies hold their main's bindings unless they override them;
`overrides` list `vars` and `modes` like any key.

```json
{ "id": "1:5", "type": "frame", "layout": { "mode": "vertical", "gap": 16 },
  "vars": { "gap": "V:4", "padding/0": "V:4" },
  "fills": [ { "type": "solid", "color": "#ffffff", "var": "V:1" } ],
  "effects": [ { "type": "drop-shadow", "color": "#00000040", "offset": [0, 2],
                 "radius": 8, "vars": { "radius": "V:5", "color": "V:6" } } ] }
```

Setting a bound field to a value its variable does not give it detaches the variable (the
binding goes, the value stays), as typing a value into a bound field does in Figma.

### What PublrEngine offers editors

The WASM engine (`engine/src/wasm.zig`) lists and resolves; every change goes through
`pe_edit_apply`, one step each, undone exactly:

- `pe_variables()`: `{ "collections": [{ "id", ...Collection }], "variables": [{ "id",
  ...Variable }] }`, in order.
- `pe_variable_value(node, ref)`: `{ "value": V | null }`, what `ref` is worth at `node` in
  its modes (`node` "": every collection's default); a composed colour is
  `{ "color", "opacity" }`.
- `pe_node_modes(node)`: `[{ "collection", "mode", "set"? }]`, the mode of every
  collection there and the node that chose it (none: the default).
- `pe_variable_table(collection)`: `{ "<variable id>": [V | null, ...] }`, every variable
  of the collection worth in each of its modes, in the collection's mode order, aliases
  followed (an alias into another collection in that collection's default mode); an
  extended collection lists its parent's variables in its own modes, its overrides in
  force. `collection` "": every variable, one value each, in the default modes (what a
  variable picker shows).
- Changes: `{"op":"variable","id":"V:1","variable":{...} | null,"index"?:n}` adds,
  replaces (a value per mode, a name, scopes, code syntax, ...) or removes a variable;
  `{"op":"collection","id":"C:1","collection":{...} | null,"index"?:n}` the same for a
  collection (its modes: adding, renaming, reordering, the default is the first);
  `{"op":"set","node":id,"props":{"vars":{...}}}` binds or unbinds node fields, a paint's
  `var` or an object's `vars` bind inside `fills`, `strokes`, `effects`, `grids`, `style`
  and `runs`; `{"op":"set","node":id,"props":{"modes":{...}}}` sets modes on a node.

