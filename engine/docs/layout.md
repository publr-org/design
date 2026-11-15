# Layout

`src/layout/layout.zig` computes every size and position that follows from rules: auto
layout (rows, columns, wrapped lines, grids), hug / fill / fixed sizing with minimum and
maximum limits, text boxes that size themselves, groups that fit their children, and
constraints when a frame changes size. Pubd files store the result (`pubd/SPEC.md`:
"positions in the file are always resolved"), so the renderer never runs it; tools run
it after an edit.

Clean room: the rules come from Figma's public help articles (auto layout, constraints,
text resizing), its public REST and Plugin API references, and from measuring our own
files. Each rule below says where it comes from.

## API

```zig
const lay = engine.relayout;
const report = try lay.relayout(gpa, &doc, &fonts, .{});           // the whole document
_ = try lay.relayoutFrom(gpa, &doc, &fonts, "12:34", null, .{});   // after editing 12:34
_ = try lay.relayoutFrom(gpa, &doc, &fonts, "12:34", size, .{});   // after resizing it
```

`relayoutFrom` lays out the edited node's subtree, then climbs: while the current node's
size follows its content (it hugs, or is auto-sized text, or a group) and its parent
arranges or fits its children (auto layout, group), the parent is laid out too. It stops
at the first ancestor whose size does not depend on its content. `pe layout-check
--incremental N` checks that this gives the same document as a full `relayout`.

Fonts are optional: without them auto-sized text keeps its stored size (counted in
`Report.unmeasured`). `measureText`, `axisMode`, `inFlow` and `constrain` are public for
the editor.

## The model

Along each axis a node is:

- `fixed`: its stored size is an input;
- `hug`: as big as its content (an auto layout frame that hugs, auto-sized text, a group);
- `fill`: what its auto layout parent gives it (`sizing.w` / `sizing.h` `fill`; only in
  the flow of an auto layout).

A child is in the flow of an auto layout when it is visible and not `absolute`; the
others keep to their constraints.

Widths never depend on heights (text wraps at its width; nothing wraps by height), so
every container solves its children's widths first, then their heights. Measuring
(`measureWidth`, `measureHeight`) is pure; `place` then writes sizes and positions top
down. A container's own fixed axis is its stored size even while it is being measured.

A size that is not a number (NaN) is unknown. Constraints need the parent's size before
the change; when it is unknown they leave the children where they are, which is right
for a document that was already laid out (and how `layout-check` works).

Positions are the top-left of the child's box in the parent: a turned or flipped child's
box is its size through its transform (it is then sized as fixed). Children of groups are
in the group's space (Pubd's convention).

## Rules

"Measured" rules come with the evidence from our corpora; turning the rule off (ablation)
makes that many stored values wrong. "Docs" rules follow Figma's help articles and are
not exercised by our files; "assumed" rules are neither, and are the first to check when
a new file disagrees.

### Text

1. **Auto width** (`width-and-height`): the width is the widest line's natural width,
   rounded up to a whole pixel (`ceil`). Measured: all 1296 + 183 auto-width texts store
   whole widths; 5 natural widths just above a whole number (188.0098 stored 189,
   295.0078 stored 296) show it is a plain `ceil` with no tolerance.
2. **The last glyph's letter spacing is not part of the width.** Measured: texts with
   negative letter spacing came out 1 to 3 px narrow while it was counted, 13 values
   wrong (Inter Semi Bold 48 px at -2 px: natural 223.02 with it, 225.02 without, stored
   226).
   `text/layout.zig` reports it per line as `Line.trail` (it does not change rendering).
3. **Auto height**: the height is the laid-out height, rounded up (`ceil`). Measured: all
   2663 + 216 auto-sized texts; rounding to the nearest pixel instead makes 363 + 126
   values wrong.
4. An auto-height text wraps at its final width (fixed, or filled from its parent).

### Auto layout (rows and columns)

5. **Positions are not rounded.** Measured: centred children sit at half pixels (3.5);
   flooring the centring makes 60 cross-axis and 25 main-axis values off by up to 0.5.
6. **Fill shares like CSS `flex: 1 1 0` with border-box sizing**: the free space is
   shared equally between the fill children's content boxes, and each child's own
   padding comes on top. Measured: a 1344 px row with a 40 px gap holds two fill frames,
   628 and 676 wide; the second has 24 px padding on both sides (an even split would be
   652 each). Without it 9 values are wrong. Clamped children (min / max) keep their
   clamp and the others share again (CSS; docs say fill respects min and max).
7. **Hug**: a row's width is its children's widths plus gaps and padding, its height the
   tallest child plus padding; a column the other way round. Fill children of a hugging
   frame do not count towards its size on the cross axis and take the result; along a
   hugging main axis they hug (docs; Figma does not offer fill there). Min / max clamp
   the result.
8. **Distribution**: `space-between` puts the free space between the children (the fixed
   gap is ignored), `space-around` half a share before the first and after the last,
   `space-evenly` equal shares everywhere. Measured on 1037 + 32 + 10 space-between
   children and one specimen each of around and evenly (treating evenly as around makes 3
   values wrong). One child with space-between sits at the start (assumed, CSS).
9. **Baseline alignment**: children of a row align their first baselines; the row is as
   tall as the highest reach above plus the lowest reach below. Measured: 92 children (all
   text); aligning their tops instead makes 48 values wrong. An auto layout frame child
   aligns by its first in-flow child with a baseline, any other child by its bottom edge
   (assumed, CSS-like).
10. **Strokes in layout** (`strokesIncluded`): a child's box grows by the part of its
    stroke outside it (outside: the weight, centre: half), and the frame's own inside
    stroke adds to its padding (docs). Our 214 frames with the setting have only inside
    strokes on their children, so it is not exercised.
11. Hidden children take no space; absolute children keep to their constraints against
    the frame (docs).

### Wrapping

12. Children fill a line along the main axis until the next one does not fit (gaps
    included), lines stack `crossGap` apart, each as tall as its tallest child; each line
    is distributed like a row; `alignContent: space-between` spreads the lines over the
    frame. Measured on 25 wrapped children (exact). Vertical wrap (columns) mirrors it
    (assumed; Figma added it in 2026-09).

### Grids

13. Columns first: `fixed` tracks take their size, `hug` tracks the widest child that
    sits in that track alone, `flex` tracks share what is left after the fixed and hug
    tracks and the gaps, in proportion to their values (CSS `minmax(0, Nfr)`); a hugging
    grid's flexible tracks hug. Rows the same with heights. A child's area spans its
    tracks and the gaps between them; `auto` and `start` align it to the area's start,
    `center` and `end` as named, unrounded; fill children take the area. Measured: 100
    grid children in 16 specimens (fixed 84 px, `1fr`, `fit-content`, spans, gaps 12 / 24
    and 8, every cell alignment), all exact.

### Groups

14. A group is the union of its visible children's boxes; when the union moves, the
    group moves and its children move back, so nothing moves on the page. Measured: 5
    groups. **A mask clips the bounds of the siblings it masks**: measured on three mask
    groups, 200 px wide (the mask) where the union is 330. Repeat groups keep their
    stored size (their copies are not children).

### Constraints

15. When a frame changes size from `old` to `new`, each child that is not in a flow moves
    or resizes: `left` / `top` stay, `right` / `bottom` move by the change,
    `left-right` / `top-bottom` grow by it, `scale` scales position and size by
    `new / old` (unrounded: 20 -> 24.8276 for 145 -> 180). `center` keeps the child's
    offset from a centre placed in whole pixels, rounded down, as Figma centres:
    `x + floor((new - w) / 2) - floor((old - w) / 2)`. Measured on our specimen of every
    combination (a 45 x 40 child at (20, 20) in a 145 x 100 frame resized to 180 x 126):
    centre lands on 37, not 37.5. The unit test "constraints: Figma's own resize" keeps
    these numbers. Children whose own size follows their content keep it.

## The oracle: `pe layout-check`

```
pe layout-check <doc.pubd> [--show N] [--instances] [--incremental N] [--text]
```

Loads the document twice, sets every value a rule decides to NaN in the working copy
(in-flow positions, hug and fill sizes, auto-sized text, groups), runs `relayout`, and
compares every node's translation and size with the stored ones: exact (within 0.01 px),
close (within 0.5 px) or wrong, grouped by rule, with the worst offenders of each.
Inputs (fixed sizes, free positions) are compared too, under `(input)` labels.
`--instances` rebuilds every unscaled instance from its component's geometry and resizes
it to its own size; `--incremental N` checks `relayoutFrom` against a full relayout after
lengthening N texts; `--text` lists auto-sized texts with their natural sizes.

Results (2026-10-15):

| Corpus | Nodes | Values decided by rules | Exact | Close | Wrong |
|---|---|---|---|---|---|
| landing (REST) | 686 | 696 | 696 | 0 | 0 |
| features (REST) | 6138 | 9881 | 9881 | 0 | 0 |
| features-fig (.fig) | 6138 | 9881 | 9881 | 0 | 0 |

Instances: features 11 instances (13 nodes, 26 values) exact; landing's 2 instances are
scaled as a whole (`scale` 0.40 and 0.73) and skipped. Incremental: 300 edits on features,
216 on landing, all identical to a full relayout. A full relayout of features takes about
25 ms.

## Not done yet

- Instances scaled as a whole (`scale`): their content is the component's at that scale
  (font sizes, strokes, radii, effects); not computed, so not checked.
- Children of groups follow constraints relative to the group's parent frame in Figma; a
  resized frame here does not reach into groups.
- Auto-width text that grows in a free frame keeps its left edge; Figma may grow centred
  and right-aligned text from its centre or right edge (not measured).
- Min / max with auto-width text (Figma wraps it at the maximum), grid auto rows and
  auto placement (`gridAutoTracks`, `gridItemsPositioning`: our cells are stored
  resolved), legacy (pre-2026) auto layout behaviour, aspect-ratio locks.
- Strokes in layout, hidden children, absolute children, single-child space-between and
  baseline alignment of non-text children are implemented from the docs or assumed and
  not exercised by our files.
