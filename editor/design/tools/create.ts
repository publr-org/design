// Drawing new layers, as Figma's shape tools do: a drag draws the layer (Shift: a square
// or circle, a line at 45° steps; Alt: from the centre), a click makes a 100 x 100 one
// there (a line 100 long). It goes into the frame under the pointer (into an auto
// layout's flow where the pink line shows), is selected, and the tool goes back to Move.
// Text: a click starts an auto width text, a drag a fixed box; typing follows at once.
//
// Glue, not UI.

import { apply, apply_, childrenOf, clean, dropAt, editing, inv, mul, newId, rotation, translate } from "./geo";
import type { Aff, Box, Pt } from "./geo";
import { BLUE, fmt, line, pill, PINK, polygon } from "./marks";
import type { Painter } from "./marks";
import { insertionSlot } from "./move";
import type { Pointer } from "./move";
import { drawGuides, SNAP_PX, snapBox, targetsIn } from "./snap";
import type { Snapped, Targets } from "./snap";

export type ShapeTool = "frame" | "rectangle" | "ellipse" | "line" | "polygon" | "star" | "text" | "slice";

const NAMES: Record<ShapeTool, string> = {
  frame: "Frame",
  rectangle: "Rectangle",
  ellipse: "Ellipse",
  line: "Line",
  polygon: "Polygon",
  star: "Star",
  text: "",
  slice: "Slice",
};
const counters: Partial<Record<ShapeTool, number>> = {};

const GREY = { type: "solid", color: "#d9d9d9" };

/** A new layer of `tool`'s kind (Figma's defaults), `w` x `h`. */
function nodeOf(tool: ShapeTool, w: number, h: number): Record<string, unknown> {
  const n = (counters[tool] = (counters[tool] ?? 0) + 1);
  const base = { id: newId(), name: tool === "text" ? "" : `${NAMES[tool]} ${n}`, size: [w, h] };
  switch (tool) {
    case "frame":
      return { ...base, type: "frame", fills: [{ type: "solid", color: "#ffffff" }], clip: true };
    case "rectangle":
      return { ...base, type: "rectangle", fills: [GREY] };
    case "ellipse":
      return { ...base, type: "ellipse", fills: [GREY] };
    case "polygon":
      return { ...base, type: "polygon", count: 3, fills: [GREY] };
    case "star":
      return { ...base, type: "star", count: 5, innerScale: 0.382, fills: [GREY] };
    case "line":
      return { ...base, type: "line", size: [w, 0], strokes: [{ type: "solid", color: "#000000" }], stroke: { weight: 1, align: "center" } };
    case "slice":
      return { ...base, type: "slice" };
    case "text":
      return { ...base, type: "text", text: "", style: { family: "Inter", fontStyle: "Regular", size: 12 }, resize: w ? "fixed" : "width-and-height", fills: [{ type: "solid", color: "#000000" }] };
  }
}

export class CreateDrag {
  readonly tool: ShapeTool;
  private start: Pt;
  private end: Pt;
  private parent: string;
  private pctm: Aff;
  private layout = false;
  private targets: Targets;
  private snapped: Snapped = { dx: 0, dy: 0, xs: [], ys: [] };
  private dragged = false;
  private box: Box;
  /** The new layer's id, once made. */
  id = "";

  constructor(tool: ShapeTool, at: Pt) {
    this.tool = tool;
    this.start = [Math.round(at[0]), Math.round(at[1])];
    this.end = this.start;
    this.box = [...this.start, ...this.start] as Box;
    const drop = dropAt(at[0], at[1], []);
    const c = drop ? childrenOf(drop.id) : null;
    this.parent = c?.id ?? "";
    this.pctm = c?.ctm ?? [1, 0, 0, 1, 0, 0];
    this.layout = !!c?.layout;
    this.targets = targetsIn(this.parent, new Set());
  }

  /** The box drawn: from the press to (x, y), Shift square, Alt from the centre. */
  move(p: Pointer, zoom: number): void {
    let [x, y] = [p.x, p.y];
    if (!this.dragged && Math.hypot(x - this.start[0], y - this.start[1]) * zoom < 3) return;
    this.dragged = true;
    if (this.tool !== "line") {
      const sn = snapBox([x, y, x, y], this.targets, SNAP_PX / zoom, [0], [0]);
      this.snapped = sn;
      x += sn.dx;
      y += sn.dy;
    }
    x = Math.round(x);
    y = Math.round(y);
    let dx = x - this.start[0];
    let dy = y - this.start[1];
    if (p.shift) {
      if (this.tool === "line") {
        const a = Math.round(Math.atan2(dy, dx) / (Math.PI / 4)) * (Math.PI / 4);
        const len = Math.hypot(dx, dy);
        dx = Math.round(Math.cos(a) * len);
        dy = Math.round(Math.sin(a) * len);
      } else {
        const s = Math.max(Math.abs(dx), Math.abs(dy));
        dx = Math.sign(dx || 1) * s;
        dy = Math.sign(dy || 1) * s;
      }
    }
    this.end = [this.start[0] + dx, this.start[1] + dy];
    const [x0, y0, x1, y1] = this.rect(p.alt);
    this.box = [x0, y0, x1, y1];
    this.place(x0, y0, x1, y1, p.alt);
  }

  private rect(alt: boolean): Box {
    const [sx, sy] = this.start;
    const [ex, ey] = this.end;
    if (alt) {
      const w = Math.abs(ex - sx);
      const h = Math.abs(ey - sy);
      return [sx - w, sy - h, sx + w, sy + h];
    }
    return [Math.min(sx, ex), Math.min(sy, ey), Math.max(sx, ex), Math.max(sy, ey)];
  }

  /** The layer made or updated to cover page box (x0, y0, x1, y1). */
  private place(x0: number, y0: number, x1: number, y1: number, alt: boolean): void {
    let ctm: Aff;
    let size: [number, number];
    if (this.tool === "line") {
      const [sx, sy] = alt ? [this.start[0] - (this.end[0] - this.start[0]), this.start[1] - (this.end[1] - this.start[1])] : this.start;
      const dx = this.end[0] - sx;
      const dy = this.end[1] - sy;
      ctm = mul(translate(sx, sy), rotation(Math.atan2(dy, dx)));
      size = [Math.hypot(dx, dy), 0];
    } else {
      ctm = translate(x0, y0);
      size = [x1 - x0, y1 - y0];
    }
    const transform = clean(mul(inv(this.pctm), ctm));
    if (!this.id) {
      const ed = editing();
      if (!ed) return;
      ed.begin();
      const node = { ...nodeOf(this.tool, size[0], size[1]), transform, size };
      this.id = node.id as string;
      apply_([{ op: "insert", parent: this.parent || pageIdOf(), index: -1, node }]);
      return;
    }
    apply_([{ op: "set", node: this.id, props: { transform, size } }]);
  }

  /** The press ends: a click makes the default size (a text: auto width, nothing to
   * draw). Answers the new layer's id ("" when none). */
  up(p: Pointer): string {
    if (!this.dragged) {
      const s = this.start;
      if (this.tool === "text") this.placeText(s);
      else if (this.tool === "line") {
        this.end = [s[0] + 100, s[1]];
        this.place(s[0], s[1], s[0] + 100, s[1], false);
      } else this.place(s[0], s[1], s[0] + 100, s[1] + 100, false);
    }
    // Into an auto layout's flow, where the pointer is.
    if (this.layout && this.id) {
      const c = childrenOf(this.parent);
      if (c?.layout) {
        const slot = insertionSlot(c, p.x, p.y, new Set([this.id]));
        apply_([{ op: "move", node: this.id, parent: this.parent, index: slot.index }]);
      }
    }
    return this.id;
  }

  /** A click with the text tool: an empty auto width text whose first line's top sits at
   * the click (the step stays open: typing follows). */
  private placeText(at: Pt): void {
    const ed = editing();
    if (!ed) return;
    ed.begin();
    const node = { ...nodeOf("text", 0, 15), transform: clean(mul(inv(this.pctm), translate(at[0], at[1] - 7))), size: [0, 15] };
    if (this.tool === "text") (node as Record<string, unknown>).size = [0, 15];
    this.id = node.id as string;
    apply_([{ op: "insert", parent: this.parent || pageIdOf(), index: -1, node }]);
  }

  /** Ends the step the layer was made in (a text's editing ends it instead). */
  commit(): void {
    if (this.id) editing()?.commit();
  }

  cancel(): void {
    if (this.id) editing()?.cancel();
    this.id = "";
  }

  draw(p: Painter): void {
    if (!this.dragged) return;
    drawGuides(p, this.box, this.targets, this.snapped);
    const b = this.box;
    if (this.tool === "line") {
      line(p, this.start, this.end, BLUE);
      const [x, y] = p.screen(this.end[0], this.end[1]);
      pill(p, fmt(Math.hypot(this.end[0] - this.start[0], this.end[1] - this.start[1])), x, y + 20, BLUE);
      return;
    }
    polygon(
      p,
      [
        [b[0], b[1]],
        [b[2], b[1]],
        [b[2], b[3]],
        [b[0], b[3]],
      ],
      BLUE,
    );
    const [cx, by] = p.screen((b[0] + b[2]) / 2, b[3]);
    pill(p, `${fmt(b[2] - b[0])} × ${fmt(b[3] - b[1])}`, cx, by + 14, BLUE);
    if (this.layout) {
      const c = childrenOf(this.parent);
      if (c?.layout) {
        const slot = insertionSlot(c, b[2], b[3], new Set(this.id ? [this.id] : []));
        line(p, slot.line[0], slot.line[1], PINK, 2);
      }
    }
    void apply;
  }
}

function pageIdOf(): string {
  return dropAt(-1e9, -1e9, [])?.id ?? "";
}
