// The canvas's tools: what a press, a drag, a double-click and the keys do on the canvas
// with each tool of the toolbar, and the marks they draw over it (overlay.ts calls
// `draw`). Selection reads the engine's live document, so it follows every edit.
//
// - Move: a click selects (the layer in the scope of the selection, Cmd the deepest,
//   Shift adds or removes), a drag moves (move.ts), the selection's handles resize and
//   rotate (resize.ts), a drag on empty canvas or on a top-level frame's background
//   selects what the box touches; a double-click dives one level in, and into a text
//   edits it (text.ts); Enter edits a selected text; arrows nudge; Alt
//   held shows distances to the layer under the pointer.
// - Scale (K): the same, the handles scaling.
// - Frame, Rectangle, Ellipse, Line, Polygon, Star, Text, Slice: draw (create.ts).
// - Hand: the stage pans (stage.ts).
//
// Glue, not UI: the notice it raises is shown by Toolbar.ptsx.

import { Publr } from "publr-jsx";
import { inComponent, select, setHover, setTool, shell, stage, targetAt as storeTargetAt } from "../store";
import type { ToolName } from "../store";
import { CreateDrag } from "./create";
import type { ShapeTool } from "./create";
import { aabbOf, apply_, childrenOf, corners, deepHit, editing, engine, geo, geos, overlaps, pageId, union } from "./geo";
import type { Box, Geo, Pt } from "./geo";
import { BLUE, crisp, distances, fmt, handle, pill, polygon, PURPLE } from "./marks";
import type { Painter } from "./marks";
import { MoveDrag, movable, nudge } from "./move";
import type { Pointer } from "./move";
import { frameOf, ResizeDrag, resizeCursor, RotateDrag, rotateCursor, zoneAt } from "./resize";
import { TextEdit } from "./text";

/** What the toolbar shows above itself (a missing font, say). */
export const canvasNotice = Publr.reactive({ text: "" });
let noticeTimer = 0;
export function notify(text: string): void {
  canvasNotice.text = text;
  clearTimeout(noticeTimer);
  noticeTimer = window.setTimeout(() => (canvasNotice.text = ""), 4000);
}

const SHAPES = new Set<ToolName>(["frame", "rectangle", "ellipse", "line", "polygon", "star", "text", "slice"]);
const ARTBOARDS = new Set(["frame", "component", "component-set"]);
/** How far (CSS px) a press moves before it is a drag. */
const DRAG_PX = 3;

type Gesture = {
  move(p: Pointer, zoom: number): void;
  up(p: Pointer): void;
  cancel(): void;
  draw(p: Painter): void;
  /** The selection box hides while it runs (a layer reordered in an auto layout). */
  quiet?(): boolean;
};

/** A surface beside the canvas a move drag may be carried to (another canvas side by
 * side): while the pointer is over it the drag is its, the layers go back where they
 * were, and it hears where the pointer is and where it is let go. */
export interface Outside {
  /** Whether the pointer is over the surface. */
  over(e: PointerEvent): boolean;
  /** The pointer over the surface, carrying layers `ids` (pressed at page point `from`). */
  move(e: PointerEvent, ids: string[], from: Pt): void;
  /** Let go over the surface. */
  drop(e: PointerEvent, ids: string[], from: Pt): void;
  /** Let go elsewhere, or the drag was cancelled. */
  leave(): void;
}

/** What the overlay gives the tools. */
export interface Host {
  painter(): Painter;
  /** CSS pixel on the canvas to page point. */
  toPage(sx: number, sy: number): Pt;
  request(): void;
  canvas: HTMLCanvasElement;
  spaceDown(): boolean;
}

export class Tools {
  private host: Host;
  private gesture: Gesture | null = null;
  private press: { start: Pt; screen: Pt; target: string; wasSelected: boolean; shift: boolean; marquee: string | null; alt: boolean } | null = null;
  text: TextEdit | null = null;
  private pointer: Pointer | null = null;
  private screenPt: Pt = [0, 0];
  private alt = false;
  private pending: Pointer | null = null;
  private frameAsked = false;
  /** The pointer moved since the press. */
  private moved = false;
  /** The last press, to count double and triple clicks (a pointerdown's `detail` is not
   * the click count). */
  private lastPress = { t: 0, x: 0, y: 0, n: 0 };
  /** Where a move drag may be carried to (null: nowhere). */
  outside: Outside | null = null;
  /** The layers a drag carried to `outside` (null while none is). */
  private carried: string[] | null = null;
  /** Where the carried drag was pressed (page point). */
  private carriedFrom: Pt = [0, 0];
  /** The last press on the canvas (page point). */
  private pressedAt: Pt = [0, 0];
  /** The gesture under way is a move (or a press on a layer that becomes one). */
  private moving = false;

  constructor(host: Host) {
    this.host = host;
    const ed = editing();
    if (ed) {
      // Undo and redo put the selection back.
      ed.selectionSource ??= () => shell.selection;
      ed.restoreSelection ??= (ids) => select(ids);
    }
  }

  private zoom(): number {
    return stage()?.cam.z ?? 1;
  }

  /** The selection, live. */
  selection(): Geo[] {
    return geos(shell.selection);
  }

  // ------------------------------------------------------------ what a click selects

  /** What a click at (x, y) selects (the store's scope-aware hit test on the live tree);
   * `deep`: the deepest layer. */
  targetAt(x: number, y: number, deep: boolean): string {
    return storeTargetAt(x, y, deep);
  }

  // ------------------------------------------------------------ the pointer

  private ptr(e: PointerEvent | MouseEvent): Pointer {
    const r = this.host.canvas.getBoundingClientRect();
    this.screenPt = [e.clientX - r.left, e.clientY - r.top];
    const [x, y] = this.host.toPage(this.screenPt[0], this.screenPt[1]);
    return { x, y, shift: e.shiftKey, alt: e.altKey, meta: e.metaKey || e.ctrlKey };
  }

  /** How many presses in a row this one is: within 500 ms and 4 px of the last. */
  private clicks(e: PointerEvent): number {
    const l = this.lastPress;
    const near = e.timeStamp - l.t < 500 && Math.abs(e.clientX - l.x) <= 4 && Math.abs(e.clientY - l.y) <= 4;
    l.n = near ? l.n + 1 : 1;
    l.t = e.timeStamp;
    l.x = e.clientX;
    l.y = e.clientY;
    return l.n;
  }

  down(e: PointerEvent): boolean {
    if (!engine() || !stage()?.doc) return false;
    const p = this.ptr(e);
    this.alt = e.altKey;
    // In a text edit: a press in the text moves the caret, outside it ends the edit.
    if (this.text) {
      if (this.text.contains(p.x, p.y, 4 / this.zoom())) {
        this.text.press(p.x, p.y, p.shift, this.clicks(e));
        const t = this.text;
        this.gesture = { move: (q) => t.drag(q.x, q.y), up: () => {}, cancel: () => {}, draw: () => {} };
        this.capture();
        return true;
      }
      this.endText();
    }
    const tool = shell.tool;
    if (SHAPES.has(tool)) {
      this.gesture = this.creating(tool as ShapeTool, p);
      this.capture();
      return true;
    }
    if (tool !== "move" && tool !== "scale") return false;
    const sel = this.selection();
    const f = frameOf(sel.filter((g) => !g.inInstance && !g.locked));
    const zone = f ? zoneAt(this.host.painter(), f, this.screenPt) : null;
    const editable = sel.filter((g) => !g.inInstance && !g.locked);
    if (zone && editable.length === sel.length) {
      this.gesture = zone.kind === "resize" ? new ResizeDrag(editable, zone.h, tool === "scale") : new RotateDrag(editable, [p.x, p.y]);
      this.capture();
      return true;
    }
    this.pressedAt = [p.x, p.y];
    const target = this.targetAt(p.x, p.y, p.meta);
    if (!target) {
      if (!p.shift) select([]);
      this.press = { start: [p.x, p.y], screen: this.screenPt, target: "", wasSelected: false, shift: p.shift, marquee: pageId(), alt: p.alt };
      this.capture();
      return true;
    }
    const wasSelected = shell.selection.includes(target);
    // A top-level frame's background: a drag there selects inside it (unless it is selected).
    const tg = geo(target);
    const marquee = tg && !wasSelected && ARTBOARDS.has(tg.type) && tg.path.length === 0 && deepHit(p.x, p.y) === target ? target : null;
    if (p.shift) select(wasSelected ? shell.selection.filter((x) => x !== target) : [...shell.selection, target]);
    else if (!wasSelected) select([target]);
    this.press = { start: [p.x, p.y], screen: this.screenPt, target, wasSelected, shift: p.shift, marquee, alt: p.alt };
    this.capture();
    this.moving = !marquee;
    this.host.request();
    return true;
  }

  private creating(tool: ShapeTool, p: Pointer): Gesture {
    const c = new CreateDrag(tool, [p.x, p.y]);
    return {
      move: (q, z) => c.move(q, z),
      up: (q) => {
        const id = c.up(q);
        if (!id) return;
        select([id]);
        setTool("move");
        if (tool === "text") this.startText(id, true, false);
        else c.commit();
      },
      cancel: () => c.cancel(),
      draw: (pt) => c.draw(pt),
    };
  }

  private capture(): void {
    this.moved = false;
    this.moving = false;
    this.carried = null;
    window.addEventListener("pointermove", this.onWindowMove);
    window.addEventListener("pointerup", this.onWindowUp);
    window.addEventListener("pointercancel", this.onWindowCancel);
  }

  private release(): void {
    window.removeEventListener("pointermove", this.onWindowMove);
    window.removeEventListener("pointerup", this.onWindowUp);
    window.removeEventListener("pointercancel", this.onWindowCancel);
  }

  /** Moves during a press: coalesced to one edit a frame. */
  private onWindowMove = (e: PointerEvent): void => {
    if (this.carry(e)) return;
    const p = this.ptr(e);
    this.pointer = p;
    const press = this.press;
    if (press && !this.gesture) {
      if (Math.hypot(this.screenPt[0] - press.screen[0], this.screenPt[1] - press.screen[1]) < DRAG_PX) return;
      this.press = null;
      if (press.marquee !== null && (!press.target || press.marquee === press.target)) {
        this.gesture = new Marquee(press.start, press.marquee, press.shift ? shell.selection : [], press.target);
      } else {
        const list = movable(this.selection());
        if (!list.length) return;
        const m = new MoveDrag(list, press.start, press.alt);
        if (m.copies.length) select(m.copies, false);
        this.gesture = { move: (q, z) => m.move(q, z), up: () => m.up(), cancel: () => m.cancel(), draw: (pt) => m.draw(pt), quiet: () => m.inFlow() };
      }
    }
    if (!this.gesture) return;
    this.moved = true;
    this.pending = p;
    if (this.frameAsked) return;
    this.frameAsked = true;
    requestAnimationFrame(() => {
      this.frameAsked = false;
      const q = this.pending;
      this.pending = null;
      if (q && this.gesture) this.run(() => this.gesture!.move(q, this.zoom()));
      this.host.request();
    });
  };

  private onWindowUp = (e: PointerEvent): void => {
    this.release();
    const carried = this.carried;
    if (carried) {
      this.carried = null;
      this.press = null;
      if (this.outside?.over(e)) this.outside.drop(e, carried, this.carriedFrom);
      else this.outside?.leave();
      this.host.request();
      return;
    }
    const p = this.ptr(e);
    const press = this.press;
    this.press = null;
    const g = this.gesture;
    this.gesture = null;
    if (g) {
      // The last place, with the keys held at the release.
      if (this.moved) this.run(() => g.move(p, this.zoom()));
      this.pending = null;
      this.run(() => g.up(p));
    } else if (press && press.target && press.wasSelected && !press.shift && shell.selection.length > 1) {
      // A click on a layer of a selection of several: it alone.
      select([press.target]);
    }
    this.host.request();
  };

  private onWindowCancel = (): void => {
    this.release();
    if (this.carried) this.outside?.leave();
    this.carried = null;
    this.press = null;
    this.gesture?.cancel();
    this.gesture = null;
    this.host.request();
  };

  /** A move drag over the surface beside: the drag goes back and the surface takes
   * it (true: the pointer is the surface's). */
  private carry(e: PointerEvent): boolean {
    const out = this.outside;
    if (!out) return false;
    if (!this.carried) {
      if (!this.moving || !shell.selection.length || !out.over(e)) return false;
      this.carried = [...shell.selection];
      this.carriedFrom = this.press?.start ?? this.pressedAt;
      this.press = null;
      const g = this.gesture;
      this.gesture = null;
      this.pending = null;
      if (g) this.run(() => g.cancel());
      this.host.request();
    }
    out.move(e, this.carried, this.carriedFrom);
    return true;
  }

  private run(fn: () => void): void {
    try {
      fn();
    } catch (err) {
      console.error("canvas tool", err);
      try {
        this.gesture?.cancel();
      } catch {
        // Nothing open.
      }
      this.gesture = null;
    }
  }

  /** The pointer over the canvas with nothing pressed: hover and cursor. */
  hover(e: PointerEvent): void {
    if (this.gesture || this.press) return;
    const p = this.ptr(e);
    this.pointer = p;
    this.alt = e.altKey;
    const s = stage();
    if (!s || !s.doc || this.host.spaceDown() || shell.tool === "hand") return;
    const canvas = this.host.canvas;
    if (SHAPES.has(shell.tool)) {
      canvas.style.cursor = shell.tool === "text" ? "text" : "crosshair";
      setHover("");
      return;
    }
    if (this.text && this.text.contains(p.x, p.y, 4 / this.zoom())) {
      canvas.style.cursor = "text";
      return;
    }
    const f = frameOf(this.selection().filter((g) => !g.inInstance && !g.locked));
    const zone = f ? zoneAt(this.host.painter(), f, this.screenPt) : null;
    canvas.style.cursor = !zone ? "" : zone.kind === "resize" ? resizeCursor(f!, zone.h) : rotateCursor(Math.atan2(zone.corner[1] - this.host.painter().screen(...centre(f!))[1], zone.corner[0] - this.host.painter().screen(...centre(f!))[0]));
    setHover(zone ? "" : this.targetAt(p.x, p.y, p.meta));
    this.host.request();
  }

  dblclick(e: MouseEvent): void {
    if (shell.tool !== "move" || this.text) return;
    const p = this.ptr(e);
    const d = deepHit(p.x, p.y);
    if (!d) return;
    const g = geo(d);
    if (!g) return;
    const path = [...g.path, d];
    const sel = shell.selection;
    // A selected text under the pointer: edit it.
    if (sel.length === 1 && sel[0] === d && g.type === "text") {
      this.startText(d, false, true);
      return;
    }
    for (const s of sel) {
      const at = path.indexOf(s);
      if (at >= 0 && at + 1 < path.length) {
        const next = path[at + 1];
        select([next]);
        if (next === d && g.type === "text") this.startText(d, false, true);
        return;
      }
    }
    const t = this.targetAt(p.x, p.y, false);
    if (t) select([t]);
    if (t === d && g.type === "text") this.startText(d, false, true);
  }

  // ------------------------------------------------------------ text

  /** Starts editing text `id` (`fresh`: just made, its step open; `all`: everything
   * selected, as Enter does). */
  startText(id: string, fresh: boolean, all: boolean, at?: Pointer): void {
    const missing = TextEdit.missing(id);
    if (missing.length) {
      notify(`${missing.join(", ")} ${missing.length > 1 ? "are" : "is"} missing. Replace the font to edit this text.`);
      if (fresh) editing()?.commit();
      return;
    }
    try {
      const t = new TextEdit(id, () => this.host.request(), fresh);
      const r = () => this.host.canvas.getBoundingClientRect();
      t.screenOf = (q) => {
        const [sx, sy] = this.host.painter().screen(q[0], q[1]);
        return [sx + r().left, sy + r().top];
      };
      t.onExit = () => {
        this.endText();
        select([id]);
      };
      t.onBlur = () => this.endText();
      if (!all && at) t.press(at.x, at.y, false, 1);
      else if (!all) t.press(Infinity, Infinity, false, 1);
      this.text = t;
      setHover("");
      this.host.request();
    } catch (err) {
      console.error("text edit", err);
      if (fresh) editing()?.commit();
    }
  }

  endText(): void {
    const t = this.text;
    if (!t) return;
    this.text = null;
    const gone = t.empty;
    t.end();
    if (gone) select(shell.selection.filter((x) => x !== t.id));
    this.host.request();
  }

  // ------------------------------------------------------------ keys

  /** Keys on the canvas (before the shell's own: Esc during a drag cancels it only). */
  key(e: KeyboardEvent): void {
    const target = e.target instanceof Element ? e.target : null;
    if (target && target !== document.body && target.closest("input, textarea, select, [contenteditable], [role=menu], [role=listbox]")) return;
    if (e.key === "Alt") {
      this.alt = true;
      this.host.request();
    }
    if (!engine() || !stage()?.doc) return;
    const stop = () => {
      e.preventDefault();
      e.stopImmediatePropagation();
    };
    if (e.key === "Escape" && (this.gesture || this.press)) {
      stop();
      this.release();
      this.gesture?.cancel();
      this.gesture = null;
      this.press = null;
      this.host.request();
      return;
    }
    if (this.gesture) return;
    const mod = e.metaKey || e.ctrlKey;
    const sel = this.selection();
    if (e.key === "Enter" && !e.shiftKey && !mod && sel.length === 1 && sel[0].type === "text") {
      stop();
      this.startText(sel[0].id, false, true);
      return;
    }
    if (e.key.startsWith("Arrow") && !mod && sel.length) {
      stop();
      const d = e.shiftKey ? 10 : 1;
      const [dx, dy] = e.key === "ArrowLeft" ? [-d, 0] : e.key === "ArrowRight" ? [d, 0] : e.key === "ArrowUp" ? [0, -d] : [0, d];
      this.run(() => nudge(sel, dx, dy));
      this.host.request();
      return;
    }
    // A, like F: the frame tool.
    if (e.code === "KeyA" && !mod && !e.shiftKey && !e.altKey) {
      stop();
      setTool("frame");
      return;
    }
    if (e.shiftKey && e.code === "Digit2" && !mod) {
      stop();
      const b = union(sel.map((g) => aabbOf(g.ctm, g.size)));
      if (b) stage()?.showRect(b[0], b[1], b[2], b[3]);
      else stage()?.fit();
    }
  }

  keyUp(e: KeyboardEvent): void {
    if (e.key === "Alt") {
      this.alt = false;
      this.host.request();
    }
  }

  // ------------------------------------------------------------ marks

  draw(p: Painter): void {
    const sel = this.selection();
    const hoverId = shell.hover;
    if (hoverId && !shell.selection.includes(hoverId) && !this.gesture) {
      const h = geo(hoverId);
      if (h) polygon(p, corners(h.ctm, h.size), colorOf(h), 2);
    }
    if (this.text) {
      this.text.draw(p);
    } else if (sel.length && !this.gesture?.quiet?.()) this.drawSelection(p, sel, !(this.gesture instanceof Marquee));
    this.gesture?.draw(p);
    // Alt: distances from the selection to the layer under the pointer (or its frame).
    if (this.alt && !this.gesture && sel.length && this.pointer) {
      const sb = union(sel.map((g) => aabbOf(g.ctm, g.size)))!;
      const t = this.targetAt(this.pointer.x, this.pointer.y, this.pointer.meta);
      let other: Box | null = null;
      if (t && !shell.selection.includes(t)) {
        const g = geo(t);
        if (g) other = aabbOf(g.ctm, g.size);
      } else if (sel[0].parent) {
        const par = geo(sel[0].parent);
        if (par) other = aabbOf(par.ctm, par.size);
      }
      if (other) distances(p, sb, other);
    }
  }

  private drawSelection(p: Painter, sel: Geo[], handles: boolean): void {
    const color = sel.every((g) => colorOf(g) === PURPLE) ? PURPLE : BLUE;
    for (const g of sel) polygon(p, corners(g.ctm, g.size), colorOf(g), 1);
    const f = frameOf(sel)!;
    const c = corners(f.ctm, f.size);
    if (sel.length > 1) polygon(p, c, color, 1);
    if (handles) for (const q of c) handle(p, q, color);
    // W x H under the box (below its lowest corner on screen).
    const box = union([aabbOf(f.ctm, f.size)])!;
    const [cx] = p.screen((box[0] + box[2]) / 2, box[3]);
    const low = Math.max(...c.map((q) => p.screen(q[0], q[1])[1]));
    pill(p, `${fmt(f.size[0])}${sizeWord("w", sel)} × ${fmt(f.size[1])}${sizeWord("h", sel)}`, cx, low + 14, color);
    void crisp;
  }

  /** The selection's box on the page, live (the rulers mark it). */
  selectionBox(): Box | null {
    const sel = this.selection();
    return union(sel.map((g) => aabbOf(g.ctm, g.size)));
  }
}

const centre = (f: { ctm: number[]; size: [number, number] }): Pt => [f.ctm[0] * (f.size[0] / 2) + f.ctm[2] * (f.size[1] / 2) + f.ctm[4], f.ctm[1] * (f.size[0] / 2) + f.ctm[3] * (f.size[1] / 2) + f.ctm[5]];

// Purple: components, instances and everything inside either, as Figma marks them.
const colorOf = (g: Geo) => (g.inInstance || g.type === "instance" || g.type === "component" || g.type === "component-set" || inComponent(g.id) ? PURPLE : BLUE);

/** A drag on empty canvas (or a top-level frame's background): the layers it touches in
 * that scope are selected (Shift: added to what was). */
class Marquee {
  private start: Pt;
  private end: Pt;
  private scope: string;
  private base: string[];
  constructor(start: Pt, scope: string, base: string[], _target: string) {
    this.start = start;
    this.end = start;
    this.scope = scope;
    this.base = base;
  }

  move(p: Pointer): void {
    this.end = [p.x, p.y];
    const box: Box = [Math.min(this.start[0], p.x), Math.min(this.start[1], p.y), Math.max(this.start[0], p.x), Math.max(this.start[1], p.y)];
    const c = childrenOf(this.scope);
    if (!c) return;
    const hit: string[] = [];
    for (const k of c.children) if (k.visible && !k.locked && overlaps(aabbOf(k.ctm, k.size), box)) hit.push(k.id);
    const ids = [...new Set([...this.base, ...hit])];
    if (ids.join() !== shell.selection.join()) select(ids, false);
  }

  up(): void {}
  cancel(): void {}

  draw(p: Painter): void {
    const [x0, y0] = p.screen(this.start[0], this.start[1]);
    const [x1, y1] = p.screen(this.end[0], this.end[1]);
    const ctx = p.ctx;
    ctx.fillStyle = "rgba(13,153,255,0.1)";
    ctx.fillRect(Math.min(x0, x1), Math.min(y0, y1), Math.abs(x1 - x0), Math.abs(y1 - y0));
    ctx.strokeStyle = BLUE;
    ctx.lineWidth = 1;
    ctx.strokeRect(Math.round(Math.min(x0, x1)) + 0.5, Math.round(Math.min(y0, y1)) + 0.5, Math.round(Math.abs(x1 - x0)), Math.round(Math.abs(y1 - y0)));
  }
}

/** " Hug" or " Fill" after the size under one selected layer that hugs or fills that way,
 * as the Design tab says it. */
function sizeWord(axis: "w" | "h", sel: Geo[]): string {
  const i = shell.inspector;
  if (sel.length !== 1 || !i || i.multi) return "";
  const v = axis === "w" ? i.wSizing : i.hSizing;
  return v === "fill" ? ` ${Publr.t("Fill")}` : v === "hug" ? ` ${Publr.t("Hug")}` : "";
}
