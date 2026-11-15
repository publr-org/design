// Smart guides: a box being moved, resized or drawn snaps its edges and centre to the
// edges and centres of the layers beside it and of the frame they are in, within a few
// screen pixels; what it snapped to is drawn as red lines through every box on that
// line. Positions land on whole pixels (the pixel grid) unless the layer is turned.
//
// Glue, not UI.

import { aabbOf, childrenOf, pageId } from "./geo";
import type { Box, Pt } from "./geo";
import { distances, line, RED } from "./marks";
import type { Painter } from "./marks";

/** How near (CSS pixels) an edge must come to snap. */
export const SNAP_PX = 5;

export type Targets = { boxes: Box[]; parent: Box | null };

/** The boxes a layer inside `parent` snaps to: its visible siblings (not `skip`) and the
 * parent's own box (a page has none). */
export function targetsIn(parent: string, skip: Set<string>): Targets {
  const c = childrenOf(parent || pageId());
  if (!c) return { boxes: [], parent: null };
  const boxes: Box[] = [];
  for (const k of c.children) if (k.visible && !skip.has(k.id)) boxes.push(aabbOf(k.ctm, k.size));
  const own = c.type === "page" ? null : aabbOf(c.ctm, c.size);
  return { boxes, parent: own };
}

/** Where a box snapped: the offset to add, and the lines it lies on. */
export type Snapped = { dx: number; dy: number; xs: number[]; ys: number[] };

/** Snaps `box`'s edges named in `xEdges` / `yEdges` (0 start, 1 centre, 2 end) to
 * `t`'s, within `tol` page units. */
export function snapBox(box: Box, t: Targets, tol: number, xEdges = [0, 1, 2], yEdges = [0, 1, 2]): Snapped {
  const all = t.parent ? [...t.boxes, t.parent] : t.boxes;
  const xsOf = (b: Box) => [b[0], (b[0] + b[2]) / 2, b[2]];
  const ysOf = (b: Box) => [b[1], (b[1] + b[3]) / 2, b[3]];
  const mine = { x: xsOf(box), y: ysOf(box) };
  let bestX = { d: tol + 1e-9, v: 0 };
  let bestY = { d: tol + 1e-9, v: 0 };
  for (const b of all) {
    for (const v of xsOf(b))
      for (const e of xEdges) {
        const d = v - mine.x[e];
        if (Math.abs(d) < Math.abs(bestX.d)) bestX = { d, v };
      }
    for (const v of ysOf(b))
      for (const e of yEdges) {
        const d = v - mine.y[e];
        if (Math.abs(d) < Math.abs(bestY.d)) bestY = { d, v };
      }
  }
  const dx = Math.abs(bestX.d) <= tol ? bestX.d : 0;
  const dy = Math.abs(bestY.d) <= tol ? bestY.d : 0;
  return { dx, dy, xs: dx || Math.abs(bestX.d) <= tol ? [bestX.v] : [], ys: dy || Math.abs(bestY.d) <= tol ? [bestY.v] : [] };
}

/** The red guides of a snapped box: each line it lies on, across it and every box that
 * lies on the same line; and the distances to its nearest neighbours on each side. */
export function drawGuides(p: Painter, box: Box, t: Targets, s: Snapped): void {
  const all = t.parent ? [...t.boxes, t.parent] : t.boxes;
  const near = (a: number, b: number) => Math.abs(a - b) < 0.01;
  const xsOf = (b: Box) => [b[0], (b[0] + b[2]) / 2, b[2]];
  const ysOf = (b: Box) => [b[1], (b[1] + b[3]) / 2, b[3]];
  for (const x of s.xs) {
    let y0 = box[1];
    let y1 = box[3];
    for (const b of all)
      if (xsOf(b).some((v) => near(v, x))) {
        y0 = Math.min(y0, b[1]);
        y1 = Math.max(y1, b[3]);
      }
    line(p, [x, y0], [x, y1], RED);
  }
  for (const y of s.ys) {
    let x0 = box[0];
    let x1 = box[2];
    for (const b of all)
      if (ysOf(b).some((v) => near(v, y))) {
        x0 = Math.min(x0, b[0]);
        x1 = Math.max(x1, b[2]);
      }
    line(p, [x0, y], [x1, y], RED);
  }
  // The nearest box on each side that overlaps on the other axis: its distance.
  const sides: (Box | null)[] = [null, null, null, null];
  const gaps = [Infinity, Infinity, Infinity, Infinity];
  for (const b of t.boxes) {
    const vOver = b[1] < box[3] && b[3] > box[1];
    const hOver = b[0] < box[2] && b[2] > box[0];
    if (vOver && b[2] <= box[0] && box[0] - b[2] < gaps[0]) [gaps[0], sides[0]] = [box[0] - b[2], b];
    if (vOver && b[0] >= box[2] && b[0] - box[2] < gaps[1]) [gaps[1], sides[1]] = [b[0] - box[2], b];
    if (hOver && b[3] <= box[1] && box[1] - b[3] < gaps[2]) [gaps[2], sides[2]] = [box[1] - b[3], b];
    if (hOver && b[1] >= box[3] && b[1] - box[3] < gaps[3]) [gaps[3], sides[3]] = [b[1] - box[3], b];
  }
  for (const b of sides) if (b) distances(p, box, b);
}

/** A page point on whole pixels. */
export const pixel = (pt: Pt): Pt => [Math.round(pt[0]), Math.round(pt[1])];
