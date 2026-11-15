# The `.fig` file, as we read it

What `src/import/fig/` reads, in our own words. Worked out from files we made ourselves
(`corpus/features/fig/complete.fig`, saved from our own Figma file), the public Kiwi format
(github.com/evanw/kiwi, MIT) and Figma's public REST and Plugin API documentation, by
comparing every structure with the REST API's answer for the same nodes. Nothing here comes
from Figma's application code or from other projects' `.fig` readers.

## Container

A `.fig` saved from Figma is a zip:

```
canvas.fig          the document
meta.json           { "file_name", "client_meta": { background, thumbnail size, … }, "exported_at" }
thumbnail.png       a small preview
images/<sha1 hex>   every image's bytes, named by the SHA-1 of the bytes, no extension:
                    the same names REST uses as `imageRef`
```

Entries are stored or deflated; the reader takes the central directory's sizes, and
zip64 end records and extra fields when a file passes 4 GB. Figma stores the images
unpacked (method 0; all 637 entries of a 672 MB file we have) and deflates `meta.json`.
`canvas.fig` is small next to the images (2.9 MB, 27 MB unpacked, in that file), so the
import reads only the zip's directory, `canvas.fig` and one image at a time
(`src/import/fig/stream.zig`); it never needs the whole file in memory.

## `canvas.fig`

```
8 bytes   "fig-kiwi"
u32 LE    format version (106 in our file)
then chunks: u32 LE length, then that many bytes
  chunk 0   the Kiwi schema (binary), compressed
  chunk 1   the document: one Kiwi `Message`, compressed
```

A chunk is zstd when it starts with the zstd magic `28 b5 2f fd`, else raw deflate (no
zlib header). Our file: schema deflated, message zstd.

## Kiwi

The schema is in the file, so the reader needs no built-in knowledge of Figma's types;
it only looks fields up by name. Encoding (see `src/import/fig/kiwi.zig` for the full
list): varint uints (LEB128), zigzag ints, a float as one zero byte for 0.0 or four bytes
whose bits are rotated left by 9, null-terminated strings, arrays as a count then the
elements (`byte[]` as raw bytes), messages as (field id, value) pairs ended by id 0,
structs as every field in order. Kiwi leaves fields at their default out of a message:
an absent bool is `false`, an absent number 0 (see "Defaults" below).

Our file's schema: 653 definitions; `NodeChange` has 616 fields.

The root is `Message`: `nodeChanges` (every node, flat), `blobs` (`{ bytes }`, binary data
that nodes point at by index), plus session fields.

## Nodes

Every `NodeChange` has a `guid` (`sessionID`, `localID`; REST writes `"<session>:<local>"`)
and, except the document, a `parentIndex`: the parent's guid and `position`, a fractional
index string. Siblings sort by `position` as bytes; the first is bottom-most (REST's
`children` order).

Pages are `CANVAS` children of `DOCUMENT`. A canvas with `internalOnly` holds the file's
styles (nodes with `styleType`), variables and brushes; it is not a page.

| `type` | Pubd | Notes |
|---|---|---|
| `CANVAS` | page | `backgroundColor` |
| `FRAME` | frame | with `resizeToFit`: a group; with `isStateGroup`: a component set (component) |
| `SECTION` | frame | REST reports no corner radius |
| `SYMBOL` | component | |
| `INSTANCE` | instance | children expanded, below |
| `TRANSFORM` | group | a repeat group (`transformModifiers`) |
| `ROUNDED_RECTANGLE`, `RECTANGLE` | rectangle | |
| `ELLIPSE`, `LINE`, `STAR`, `REGULAR_POLYGON` | same | `arcData`, `count`, `starInnerScale` |
| `BOOLEAN_OPERATION` | boolean | `booleanOperation`: `UNION`, `INTERSECT`, `SUBTRACT`, `XOR` |
| `VECTOR` | vector | `vectorData` |
| `TEXT`, `TEXT_PATH` | text | a text path also has `vectorData` (its path) |
| `SLICE` | slice | |
| `BRUSH` | (brush definition) | on the internal page; read when a stroke uses it |
| `VARIABLE`, `VARIABLE_SET` | `variables`, `collections` | values per mode ("Variables" below) |

Other types are skipped and counted.

Field names that differ from REST, and how they map:

- `transform` `{ m00 m01 m02 m10 m11 m12 }` is REST's `relativeTransform` rows.
- `fillPaints`, `strokePaints`, `effects`; `frameMaskDisabled` is `!clipsContent`.
- Paint: gradient `stops` and `transform`: the transform maps the node's unit square into
  gradient space, where a linear gradient runs from (0, .5) to (1, .5) (width handle (0, 1))
  and the others are centred at (.5, .5) reaching (1, .5) and (.5, 1). REST's handle
  positions are those points mapped back by the inverse. Image paints: `image.hash` (the
  SHA-1 bytes, hex = file name), `imageScaleMode` (`FILL`, `FIT`, `TILE`, `STRETCH`), `scale`
  (REST's `scalingFactor`), `transform` (REST's `imageTransform`), `rotation`. Patterns:
  `sourceNodeId`, `patternTileType`, `patternSpacing`, `scale`, alignments.
- Effects: `FOREGROUND_BLUR` is REST's `LAYER_BLUR`, `GRAIN` its `TEXTURE`; `blurOpType`
  `PROGRESSIVE` with `startOffset`, `endOffset`, `startRadius`; noise `noiseSize` is a
  vector (REST gives its x only), plus `seed`.
- Corners: `cornerRadius` and `rectangle{TopLeft,TopRight,BottomRight,BottomLeft}CornerRadius`,
  `cornerSmoothing`.
- Strokes: `strokeWeight`, `strokeAlign`, `strokeCap`, `strokeJoin`, `miterLimit`,
  `dashPattern`; per-side weights `border{Top,Right,Bottom,Left}Weight` when
  `borderStrokeWeightsIndependent` (a missing side is 0; four equal sides are reported by
  REST as one `strokeWeight`).
- Auto layout: `stackMode` (`HORIZONTAL`, `VERTICAL`, `GRID`), `stackSpacing`,
  `stackCounterSpacing`, padding `stackHorizontalPadding` (left), `stackVerticalPadding`
  (top), `stackPaddingRight`, `stackPaddingBottom`, `stackPrimaryAlignItems`,
  `stackCounterAlignItems`, `stackPrimarySizing` / `stackCounterSizing` (`FIXED`,
  `RESIZE_TO_FIT`, `RESIZE_TO_FIT_WITH_IMPLICIT_SIZE`), `stackWrap`, `stackReverseZIndex`.
  Children: `stackPositioning` `ABSOLUTE`, `stackChildPrimaryGrow` (fills along the
  parent's axis), `stackChildAlignSelf` `STRETCH` (fills across it). REST's
  `layoutSizing*` is derived from these and the child's own layout or text resizing.
  `stackPrimaryAlignItems` also takes `SPACE_AROUND` and `SPACE_EVENLY_CSS` (REST
  `SPACE_EVENLY`); `stackCounterAlignContent` `SPACE_BETWEEN` spreads wrapped lines (REST
  `counterAxisAlignContent`); `bordersTakeSpace` is REST's `strokesIncludedInLayout`.
  `minSize` / `maxSize` `{ value: { x, y } }` are REST's `minWidth`, `minHeight`,
  `maxWidth`, `maxHeight` (a minimum of 0 and a maximum that is not a number mean none).
- Grid layout (`stackMode` `GRID`): `gridColumns` / `gridRows` `{ entries[] { id,
  position } }` list the tracks (ordered by `position` like children), `gridColumnsSizing`
  / `gridRowsSizing` `{ entries[] { id, trackSize { minSizing, maxSizing { type FIXED |
  FLEX | HUG, value } } } }` size them (REST spells them as CSS: `84px`,
  `minmax(0,1fr)`, `fit-content(100%)`), `gridColumnGap`, `gridRowGap`. A child names its
  cell by track id: `gridColumnAnchor`, `gridRowAnchor` (REST `gridColumnAnchorIndex`,
  `gridRowAnchorIndex`), `gridColumnSpan`, `gridRowSpan` (absent: 1),
  `gridChildHorizontalAlign`, `gridChildVerticalAlign` (`AUTO`, `MIN`, `CENTER`, `MAX`).
  Not imported: `gridAutoTracks`, `gridItemsPositioning`, `gridReflowEnabled` (cells are
  stored resolved).
- Constraints: `horizontalConstraint` / `verticalConstraint`: `MIN`, `MAX`, `STRETCH`,
  `CENTER`, `SCALE` (REST: LEFT/TOP, RIGHT/BOTTOM, LEFT_RIGHT/TOP_BOTTOM, …).
- Layout grids: `pattern` `STRIPES` (with `axis` X: columns, Y: rows) or `GRID`; `type` is
  the alignment (`MIN`, `CENTER`, `STRETCH`, `MAX`); `numSections`, `gutterSize`, `offset`,
  `sectionSize`. REST reports a stretched grid's section size resolved against the frame.
- Masks: `mask`, `maskType` `ALPHA`, `OUTLINE` (REST `VECTOR`), `LUMINANCE`.
- Repeat: `transformModifiers[]` `{ type: REPEAT, repeatType LINEAR | RADIAL, count,
  offset: vector, axis X | Y }`.
- Styles: `styleIdForFill`, `styleIdForStrokeFill`, `styleIdForEffect`, `styleIdForText`,
  `styleIdForGrid` point at style nodes. **The style node's values win**: a node's own
  copies can be stale (we saw text whose own `fontName` said Inter while its style, and
  REST, said IBM Plex Mono), and a node following a fill style may store no `fillPaints`.

### Text

`textData`: `characters`, `characterStyleIDs` (one per UTF-16 unit; trailing zeros left
out), `styleOverrideTable` (partial nodes keyed by `styleID`: `fontName`, `fillPaints`,
`textDecoration`, …), `lines[]` (`lineType` `PLAIN`, `ORDERED_LIST`, `UNORDERED_LIST`, …,
`indentationLevel`). Node fields: `fontName` `{ family, style }` (REST derives
`fontWeight` from the style name; a `wght` entry in `fontVariations` wins: axis tag
`0x77676874`), `fontSize`, `lineHeight` `{ value, units }` (`RAW`: times the font size,
REST `FONT_SIZE_%`; `PERCENT` 100: the font's own, REST `INTRINSIC_%`; `PIXELS`),
`letterSpacing` `{ value, units PERCENT | PIXELS }` (REST: pixels), `textCase`,
`fontVariantCaps` (`SMALL`, `ALL_SMALL`: small caps), `textDecoration`,
`textDecorationStyle` (`SOLID`, `DOTTED`, `WAVY`), `textDecorationSkipInk`,
`textAutoResize` (absent: fixed; a fixed box with `textTruncation` `ENDING` is REST's
`TRUNCATE`), `textAlignHorizontal`, `textAlignVertical`, `maxLines`, `leadingTrim`,
`hangingPunctuation`, `hangingList`, `textWrapStyle`, `paragraphSpacing`,
`paragraphIndent`, `textPathStart` `{ tValue, forward }`.

`derivedTextData` is Figma's own layout of the text, stored with every text node (and,
for texts inside instances whose characters an override changed, in the instance's
`derivedSymbolData`):

- `layoutSize`: the box it laid the text out in.
- `baselines[]` `{ position { x, y }, width, lineY, lineHeight, lineAscent,
  firstCharacter, endCharacter }`: one per line, node space.
- `glyphs[]` `{ commandsBlob, position { x, y }, fontSize, firstCharacter, advance,
  rotation, styleID, emojiCodePoints }`: one per glyph. `commandsBlob` is the glyph's
  outline as a commands blob (below) in ems with y up (a cap height near 0.7), drawn at
  `position` (the origin on the baseline, node space) scaled by `fontSize`; glyphs of the
  same character share a blob, so a file holds each outline once (524 outlines for the
  21,000 texts of a file we have). `firstCharacter` is the UTF-16 index the glyph draws
  (its run gives the paints); `advance` is in ems.
- `decorations[]` `{ rects[] { x, y, w, h }, styleID }`: underlines and strikethroughs,
  node space; `styleID` is a character style id (`characterStyleIDs`).
- Figma draws each line's baseline on a whole unit of the node's space although the
  stored glyph positions keep the fraction (a baseline at 18.4 draws at 18): the renderer
  rounds a stored glyph's y (unrotated glyphs) as our own layout does.
- `fontMetaData`, `logicalIndexToCharacterOffsetMap`, `derivedLines`, `truncationStartIndex`,
  `hyperlinkBoxes`, … (not read).

So a file carries everything needed to draw its text exactly as Figma did without the
fonts. The importer keeps it as the text's laid-out cache (`Text.glyphs`, ../pubd/SPEC.md),
drawn while a font the text asks for is missing; with the font, the text is laid out from
its rules. Where a text property replaced the characters and no new layout came with
them, the stored layout is the component's and is left out.

### Instances

An instance stores its own properties (fills, size, …) and `symbolData` `{ symbolID,
symbolOverrides[] }`, but not its children: those are the component's, expanded by the
reader. REST names them `I<instance id>;<component child id>`, and deeper
`I<outer>;<nested instance>;<child>`.

- `symbolOverrides[]`: partial nodes with a `guidPath` (`guids`: the path of instance
  guids inside the component, ending at the node). They replace those fields.
- `derivedSymbolData[]`: the same shape, Figma's resolved layout for the instance (sizes,
  transforms, text layout); applied after the overrides.
- `componentPropAssignments[]` `{ defID, value }`: property values. A component's nodes
  consume them through `parameterConsumptionMap.entries[]` (`variableField` `TEXT_DATA`,
  `VISIBLE`, `OVERRIDDEN_SYMBOL_ID`; `variableData.value.propRefValue.defId`); older files
  use `componentPropRefs`.
- A nested instance is expanded the same way with its own overrides plus the outer ones
  whose path starts with it (the outer win). A swapped nested instance
  (`OVERRIDDEN_SYMBOL_ID` or `overriddenSymbolID`) takes the new component's look and name
  and keeps its own place (transform, layout child fields).
- Overrides on the component itself (`guidPath` = the component's guid) are already in the
  instance's own fields.
- A component copied in from a library keeps, on each of its nodes, the guid the node had
  in the library as `overrideKey`; `guidPath`s (overrides and `derivedSymbolData`) name
  such nodes by that key, not by their guid here. A path step matches a node by either.
  (4,483 of the 72,000 nodes of a file we have carry one; without it an instance shows its
  component's text, fills and layout instead of its own.)

### Style links

A node follows a style through `styleIdForFill`, `styleIdForStrokeFill`, `styleIdForText`,
`styleIdForEffect` and `styleIdForGrid`: a `{ guid }` for the file's own style, or, for a
library's style copied into the file, `{ assetRef { key, version } }`, matched by the style
node's `key`. (In Caraway's design-system file, 16,031 of the first 100,000 node records link a style
by key and 1,452 by guid; read by guid only, no visible node followed a style, by key
19,356 do.) A grid style's guides are its
`layoutGrids`.

### Variables

`VARIABLE_SET`, `VARIABLE` and `VARIABLE_OVERRIDE` nodes sit on the internal page. A set
lists its modes (`variableSetModes[]` `{ id, name, sortPosition, parentVariableSetId?,
parentModeId? }`; the first by `sortPosition` is the default; the parent fields make it an
extended collection), and has `isPublishable` (false: hidden from publishing). A variable
has `variableSetID`, `variableResolvedType` (`COLOR`, `FLOAT`, `STRING`, `BOOLEAN`),
`variableDataValues.entries[]` `{ modeID, variableData }`, `variableScopes[]`,
`codeSyntax.entries[]` `{ platform: WEB | ANDROID | iOS, value }`, `description`,
`isPublishable` and `isSoftDeleted` (deleted, still used). `variableData.value` is a value
(`colorValue`, `floatValue`, `textValue`, `boolValue`), an `alias` of another variable, or
an `expressionValue` `COMPOSE_COLOR` of a colour and a number (the opacity in percent;
bound to a paint, Figma stores the colour with alpha 1 and the paint's opacity). A
`VARIABLE_OVERRIDE` (an extended collection's own values) names the variable
(`overriddenVariableId`) and the extension (`variableSetID`); we have seen none in a file.

A variable or set copied from a library has the library's `key` and its `version`, and
references name it by `assetRef { key, version }` instead of a `guid`. One library
variable can be copied in several times, once per version the file used (28 keys of the
161 variables of a file we have): a reference finds the copy of its version. A reference
to a version the file does not hold is kept unresolved and the field keeps its value.

Bindings on a node are entries of `parameterConsumptionMap` (and, in older files, also of
`variableConsumptionMap`, the same entries) whose `variableData.value` is an `alias`
(component property references there have `propRefValue`); `variableField` names the
field (`STACK_SPACING`, `STACK_PADDING_LEFT`, `RECTANGLE_TOP_LEFT_CORNER_RADIUS`,
`BORDER_TOP_WEIGHT`, `WIDTH`, `OPACITY`, `VISIBLE`, `TEXT_DATA`, `FONT_SIZE`,
`LINE_HEIGHT`, `LETTER_SPACING`, `PARAGRAPH_SPACING`, `PARAGRAPH_INDENT`,
`FONT_FAMILY`, `FONT_STYLE` (a string, or `fontStyleValue { asString, asFloat }`), ...).
An entry with no `variableData` in an instance override unbinds the field. The topmost
layer (override, or the node) with a map of either kind gives all of a node's bindings,
and a layer above it that sets a field's own value with no binding of its own gives the
field that value (Figma keeps the main's binding beside an instance's own value). A
swapped nested instance keeps the replaced node's map for its component properties, but
its bound fields are the new component's. Inside an instance scaled as a whole
(`symbolData.uniformScaleFactor`, Pubd `scale`) a binding is an `expressionValue`
`MULTIPLY(scale, alias)`, and the stored lengths are scaled (text sizes are not): the
importer reads the alias and resolving multiplies by the instance's scale. Text runs
bind in their `styleOverrideTable` entries. Paints bind with `colorVar` and `opacityVar`;
gradient stops in `stopsVar[]` `{ color, colorVar, position }` (not in `stops`); effects
with `colorVar`, `radiusVar`, `spreadVar`, `xVar`, `yVar`, `noiseSizeXVar`,
`noiseSizeYVar`, `secondaryColorVar` (and glass and progressive-blur fields Pubd has no
place for); layout grids with `numSectionsVar`, `gutterSizeVar`, `offsetVar`,
`sectionSizeVar`; an instance's property value with `componentPropAssignments[].varValue`.
A node sets modes with `variableModeBySetMap.entries[]` `{ variableSetID, variableModeID,
variableSetExtensionID? }`.

An absent per-corner radius (`rectangleTopLeftCornerRadius`) with
`rectangleCornerRadiiIndependent` set is 0, not `cornerRadius`; the importer's reading
falls back to `cornerRadius`, so a corner bound to a 0 variable comes out right only by
resolving.

Units: an opacity variable is a percentage (0.4 gives a node opacity 0.004), line height
and letter spacing variables are pixels. A width or height binding holds only on a fixed
axis: a frame that fills its auto layout keeps the width layout gives it (three such
frames of a file we have are bound to a 1280 variable at 1024 and 1540).

A paint's `color` beside its `colorVar` is a copy made when it was last edited and can be
stale: we saw a text fill whose copy said gold while its variable, and Figma's render,
said white. The importer stores every variable, collection and binding (pubd/SPEC.md
"Variables") and sets each bound field to its variable's value in the modes the node is
in (`pubd/vars.zig`). Counts: complete.fig 58 variables in 2 collections, 5,030 bindings,
no stale copy; 2024 Caraway Month 43 in 13, 10,631, none stale; the Caraway design system
161 in 28 (27 from libraries), 187,255 bindings, 13 nodes whose copies disagreed with
their variables (instance copies whose override says padding 67 beside a binding to a
variable that is 60 at the version referenced; the variable wins, as Figma resolves
bindings when it draws), and one fill whose colour now comes from the variable copy of
the version its reference names rather than another copy with the same key. Untitled UI
PRO VARIABLES (v7.0): 821 variables (710 colour, 101 number, 10 string) in 12
collections (4 from libraries, 15 modes; "1. Color modes" Light and Dark), 620 aliases (598
across collections, chains two deep), 401 scoped, 1,980,366 bindings (none to a variable
the file lacks), 1,341 nodes setting a mode (1,281 Dark), 602 of 1,389 styles bound; no
code syntax, no extended collection. 10,077 nodes came out different from their stored
copies, the kinds above: shadows of panels set to Dark whose effect style says light,
per-corner radii, a swapped instance's paddings. Pages rendered resolved against the
same pages as imported before variables: 99.90% of pixels within 2/255 over 61 boards
(the differences are those shadows and corners).

## Blobs

### Commands (`fillGeometry[].commandsBlob`, `strokeGeometry[].commandsBlob`, glyphs)

A run of commands, each a byte then little-endian f32 coordinates:

| byte | command | floats |
|---|---|---|
| 0 | close | 0 |
| 1 | move to | x y |
| 2 | line to | x y |
| 3 | quadratic to | cx cy x y |
| 4 | cubic to | c1x c1y c2x c2y x y |

In node space, the same numbers REST prints in `fillGeometry` / `strokeGeometry` `path`
(REST rounds to 6 significant digits; the blob has the full f32). Glyph outlines start
with a close and use quadratics; shapes use 1, 2, 4 and 0. An empty blob is an empty path.
Each geometry entry also has `windingRule` (`NONZERO`, `ODD`) and `styleID` (REST
`overrideID`): a vector region's fills come from `vectorData.styleOverrideTable` entry with
that `styleID`.

### Vector network (`vectorData.vectorNetworkBlob`)

Little-endian 32-bit words:

```
u32 vertex count, u32 segment count, u32 region count
vertex   (3 words):  u32 style id, f32 x, f32 y
segment  (7 words):  u32 style id, u32 start vertex, f32 start tangent x, y,
                     u32 end vertex, f32 end tangent x, y
region:              u32 (style id << 1) | (1 nonzero, 0 even-odd), u32 loop count,
                     each loop: u32 segment count, then the segment indices
```

Positions are in `vectorData.normalizedSize` space, the numbers REST gives in
`vectorNetwork` (the importer fits them to the node's size). The style id is REST's `meta`.
(The REST importer reads REST's `windingRule: "odd"` as nonzero; the blob says even-odd.)

## Brushes and stroke extras

- `strokeBrushGuid` names a `BRUSH` node on the internal page: `brushType` `STRETCH` or
  `SCATTER`, its shape (`fillGeometry`, `vectorData`, `size`), `scatterStrokeSettings`
  `{ gap, wiggle, angularJitter, rotation, sizeJitter }`.
- On the stroked node: `stretchStrokeSettings` `{ orientation FORWARD | REVERSE }`,
  `scatterStrokeSettings` (its own; gap 1 and zeros in our file), and
  `scatterBrushTransforms[]` (a matrix per stamp, brush space to node space).
- `variableWidthPoints[]` `{ position, ascent, descent, segmentId }`: a variable-width
  stroke, widths as fractions of the weight.
- `dynamicStrokeSettings` `{ frequency, wiggle, smoothen }` (and `strokeSeed`).

`strokeGeometry` is the resolved result of all of these.

## Numbers that are not numbers

Floats in the file can be NaN; our reader takes such a value as absent (`View.float`
answers null). In the 672 MB file we have, every NaN is one of these, all in Figma's own
data (not in our instance or override resolution):

- `size` NaN (x and y) on 168 groups (`FRAME` with `resizeToFit`) whose children are all
  hidden: a group's box is the union of its visible children, and with none it has none.
  Instances copy them (218 groups after expansion; one `derivedSymbolData` entry carries
  the same NaN size). The importer fits such a group as the layout engine does
  (`layout.storedGroupBox`: the union of its visible children); with nothing visible its
  size is 0, which agrees with the file's own numbers: a hugging auto layout whose only
  child is such a group stores 0 x 0.
- `transform` with NaN `m02`/`m12` (translation) on 3 of those groups, each inside a
  vertical auto layout (13 after instance expansion). The flow decides where an auto
  layout child sits, so the importer asks the layout engine to arrange the parent (a copy
  of it) and takes the child's place from there: one group lands at 0, 0 (the only child
  of a hugging column), one at y = 70.36 (after a 52.36-tall sibling and the 18 gap).
  Outside an auto layout nothing in the file says where such a node is; it would sit at
  its parent's origin (none seen).
- `stackCounterSpacing` NaN on 20 auto layout frames, none of which wraps (the counter
  spacing is the gap between wrapped lines, unused without `stackWrap`): taken as absent,
  0, Kiwi's default and REST's `counterAxisSpacing` default.

Pubd has no spelling for NaN: the writer refuses a non-finite number (naming the node and
field) and the reader refuses `nan`/`inf` words and numbers too large for a float.

## Defaults

Kiwi omits defaults, and so some fields mean something when absent:
`textDecorationSkipInk` absent is off (Figma draws such an underline through
descenders); `stackPrimarySizing` absent hugs, `stackCounterSizing` absent is fixed;
paddings, spacing and `cornerRadius` absent are 0; `frameMaskDisabled` absent clips.
`visible` and `opacity` are written on every drawn node in our file.

## What the file has that REST does not

Imported into Pubd now: the grain's width and height (`noiseSize` x and y), the noise
seed, text decoration style, skip ink, brushes (shape, kind, orientation, scatter settings,
resolved stamps), variable width points, dynamic stroke settings, full-precision path
numbers.

In the file, not imported yet: `fontVariations`
beyond weight, Figma's own text layout (`derivedTextData`: glyph outlines, positions,
baselines), `paintFilter` (image adjustments), `authoredColor` (colour
space), `strokeSeed`, component property definitions, `exportSettings`, guides, the
document colour profile. (Image paint `rotation` is in both, and in neither importer yet.)
