// Moving layers on the canvas, as Figma's Move tool does:
// - a drag moves the selection as one undo step; Shift keeps it on one axis; it snaps to
//   the layers beside it and to its frame (red guides and distances) and lands on whole
//   pixels; Alt-drag moves copies and leaves the originals;
// - dragged over a frame it goes into that frame, dragged out of one it leaves it (Cmd
//   or Ctrl held: it stays where it is in the tree);
// - in an auto layout it keeps its place in the flow while dragged: it follows the
//   pointer, its slot moves among the others as it passes them (the Layers panel with
//   it), nothing snaps, and it drops into the slot; the selection box hides meanwhile;
// - arrow keys nudge by 1 px (10 with Shift); in an auto layout they reorder.
//
// Glue, not UI.

import { aabbOf, apply, apply_, childrenOf, clean, editing, engine, geos, inv, mul, newId, translate, turned, union } from "./geo";
import type { Aff, Box, Children, Geo, Pt } from "./geo";
import { dropAt } from "./geo";
import type { Painter } from "./marks";
import { drawGuides, SNAP_PX, snapBox, targetsIn } from "./snap";
import type { Snapped, Targets } from "./snap";

export type Pointer = { x: number; y: number; shift: boolean; alt: boolean; meta: boolean };

/** One layer being moved. */
type Moving = {
  id: string;
  /** Where it was when the drag began. */
  ctm: Aff;
  size: [number, number];
  /** Its parent now (it changes as it is dragged into frames), and that parent's ctm. */
  parent: string;
  pctm: Aff;
  /** It was out of the flow before the drag (it stays so). */
  wasAbsolute: boolean;
};

/** Where in an auto layout a drop lands: the parent, the index, and the line drawn. */
type Slot = { parent: string; index: number; line: [Pt, Pt] };

/** The layers a drag moves: the selection less what is locked, inside an instance, or
 * inside another selected layer. */
export function movable(sel: Geo[]): Geo[] {
  const ids = new Set(sel.map((g) => g.id));
  return sel.filter((g) => !g.locked && !g.inInstance && !g.path.some((a) => ids.has(a)) && g.page !== null);
}

export class MoveDrag {
  private start: Pt;
  private nodes: Moving[] = [];
  private box0: Box;
  private targets: Targets = { boxes: [], parent: null };
  private snapped: Snapped = { dx: 0, dy: 0, xs: [], ys: [] };
  private box: Box;
  private began = false;
  private noReparent = false;
  readonly ids: string[];
  /** Copies were made (Alt): the selection becomes them. */
  copies: string[] = [];

  constructor(sel: Geo[], start: Pt, alt: boolean) {
    this.start = start;
    const ed = editing();
    if (!ed) throw new Error("no document open for editing");
    ed.begin();
    this.began = true;
    let list = sel;
    if (alt) list = this.duplicate(sel);
    this.nodes = list.map((g) => ({ id: g.id, ctm: g.ctm, size: g.size, parent: g.parent, pctm: g.pctm, wasAbsolute: g.absolute }));
    this.ids = this.nodes.map((n) => n.id);
    this.box0 = union(this.nodes.map((n) => aabbOf(n.ctm, n.size)))!;
    this.box = this.box0;
    // Layers in the flow keep their slots there while the drag moves them (in a frame
    // without auto layout holding does nothing).
    const held = this.nodes.filter((n) => !n.wasAbsolute).map((n) => n.id);
    if (held.length) ed.hold(held);
    this.refreshTargets();
  }

  /** Copies of `sel` above each original (new ids; an instance's content keeps its
   * paths), selected instead of them. */
  private duplicate(sel: Geo[]): Geo[] {
    const e = engine()!;
    const changes: unknown[] = [];
    const out: string[] = [];
    for (const g of sel) {
      const json = e.canvasSubtree(g.id);
      const copy = renumber(json);
      const parent = childrenOf(g.parent);
      const index = parent ? parent.children.findIndex((c) => c.id === g.id) + 1 : -1;
      changes.push({ op: "insert", parent: g.parent, index, node: copy });
      out.push(copy.id as string);
    }
    apply_(changes);
    this.copies = out;
    return geos(out);
  }

  private refreshTargets(): void {
    const parent = this.nodes[0]?.parent ?? "";
    this.targets = targetsIn(parent, new Set(this.ids));
  }

  /** The pointer moved to `p` (page units; `zoom` CSS pixels per unit). */
  move(p: Pointer, zoom: number): void {
    let dx = p.x - this.start[0];
    let dy = p.y - this.start[1];
    if (p.shift) {
      if (Math.abs(dx) > Math.abs(dy)) dy = 0;
      else dx = 0;
    }
    this.noReparent = p.meta;
    // Into or out of frames: the frame under the pointer takes the layers.
    if (!this.noReparent) this.reparent(p.x, p.y);
    // Snapping (not while reordering a flow), then whole pixels.
    const moved: Box = [this.box0[0] + dx, this.box0[1] + dy, this.box0[2] + dx, this.box0[3] + dy];
    const none: Snapped = { dx: 0, dy: 0, xs: [], ys: [] };
    this.snapped = this.inFlow() ? none : snapBox(moved, this.targets, SNAP_PX / zoom, p.shift && dx === 0 ? [] : [0, 1, 2], p.shift && dy === 0 ? [] : [0, 1, 2]);
    dx += this.snapped.dx;
    dy += this.snapped.dy;
    const rigid = this.nodes.some((n) => turned(n.ctm));
    if (!rigid) {
      dx = Math.round(this.box0[0] + dx) - this.box0[0];
      dy = Math.round(this.box0[1] + dy) - this.box0[1];
    }
    this.box = [this.box0[0] + dx, this.box0[1] + dy, this.box0[2] + dx, this.box0[3] + dy];
    const changes: unknown[] = [];
    for (const n of this.nodes) {
      const ctm: Aff = [n.ctm[0], n.ctm[1], n.ctm[2], n.ctm[3], n.ctm[4] + dx, n.ctm[5] + dy];
      changes.push({ op: "set", node: n.id, props: { transform: clean(mul(inv(n.pctm), ctm)) } });
    }
    apply_(changes);
    this.reorder(p.x, p.y);
  }

  /** The layers sit in an auto layout's flow (held there). */
  inFlow(): boolean {
    const n = this.nodes[0];
    if (!n || n.wasAbsolute) return false;
    return !!childrenOf(n.parent)?.layout;
  }

  /** In an auto layout: the layers' slots move to where the pointer is in the flow. */
  private reorder(x: number, y: number): void {
    if (!this.inFlow()) return;
    const c = childrenOf(this.nodes[0].parent);
    if (!c) return;
    const held = this.nodes.filter((n) => !n.wasAbsolute && n.parent === c.id).map((n) => n.id);
    const slot = insertionSlot(c, x, y, new Set(this.ids));
    const now = c.children.map((k) => k.id);
    const want = now.filter((id) => !held.includes(id));
    want.splice(slot.index, 0, ...held);
    if (want.every((id, i) => id === now[i])) return;
    apply_(held.map((id, i) => ({ op: "move", node: id, parent: c.id, index: slot.index + i })));
  }

  /** Moves the layers into the frame under (x, y) when it is not their parent. */
  private reparent(x: number, y: number): void {
    const drop = dropAt(x, y, this.ids);
    if (!drop) return;
    const changes: unknown[] = [];
    let moved = false;
    for (const n of this.nodes) {
      if (drop.id === n.parent) continue;
      const to = childrenOf(drop.id);
      if (!to) continue;
      // Kept where it is on the page: its transform in the new parent's space.
      const now = geos([n.id])[0];
      if (!now) continue;
      // Into an auto layout: into its flow where the pointer is (held there).
      const index = to.layout && !n.wasAbsolute ? insertionSlot(to, x, y, new Set(this.ids)).index : to.children.length;
      changes.push({ op: "move", node: n.id, parent: drop.id, index });
      changes.push({ op: "set", node: n.id, props: { transform: clean(mul(inv(to.ctm), now.ctm)) } });
      n.parent = drop.id;
      n.pctm = to.ctm;
      moved = true;
    }
    if (changes.length) apply_(changes);
    if (moved) this.refreshTargets();
  }

  draw(p: Painter): void {
    if (!this.inFlow()) drawGuides(p, this.box, this.targets, this.snapped);
  }

  /** The drag ends: layers held in a flow drop into their slots (the step lets go). */
  up(): string[] {
    this.finish(false);
    return this.ids;
  }

  cancel(): void {
    this.finish(true);
  }

  private finish(cancel: boolean): void {
    if (!this.began) return;
    this.began = false;
    const ed = editing();
    if (!ed) return;
    if (cancel) ed.cancel();
    else ed.commit();
  }
}

/** Where a layer dropped at (x, y) lands in auto layout `c`'s flow (ignoring `skip`):
 * before the first in-flow child whose middle lies past the point on the flow's axis. */
export function insertionSlot(c: Children, x: number, y: number, skip: Set<string>): Slot {
  const vertical = c.layout!.mode === "vertical";
  const flow = c.children.filter((k) => k.visible && !k.absolute && !skip.has(k.id));
  const local = apply(inv(c.ctm), x, y);
  let at = flow.length;
  for (let i = 0; i < flow.length; i++) {
    const b = aabbOf(mul(inv(c.ctm), flow[i].ctm), flow[i].size);
    const mid = vertical ? (b[1] + b[3]) / 2 : (b[0] + b[2]) / 2;
    if ((vertical ? local[1] : local[0]) < mid) {
      at = i;
      break;
    }
  }
  // The line: across the frame between the neighbours (in the frame's space, then the page's).
  const pad = c.layout!.padding;
  const [w, h] = c.size;
  const boxOf = (k: (typeof flow)[number]) => aabbOf(mul(inv(c.ctm), k.ctm), k.size);
  let pos: number;
  if (!flow.length) pos = vertical ? pad[0] : pad[3];
  else if (at === 0) pos = (vertical ? boxOf(flow[0])[1] : boxOf(flow[0])[0]) - c.layout!.gap / 2;
  else if (at === flow.length) pos = (vertical ? boxOf(flow[at - 1])[3] : boxOf(flow[at - 1])[2]) + c.layout!.gap / 2;
  else pos = ((vertical ? boxOf(flow[at - 1])[3] : boxOf(flow[at - 1])[2]) + (vertical ? boxOf(flow[at])[1] : boxOf(flow[at])[0])) / 2;
  const a: Pt = vertical ? [pad[3], pos] : [pos, pad[0]];
  const b: Pt = vertical ? [w - pad[1], pos] : [pos, h - pad[2]];
  // The index among all the frame's children: after the in-flow child before it.
  const index = at === 0 ? (flow.length ? c.children.findIndex((k) => k.id === flow[0].id) : c.children.length) : c.children.findIndex((k) => k.id === flow[at - 1].id) + 1;
  // A layer moving within its own frame counts out of the list it is taken from.
  let adj = index;
  for (let i = 0; i < index; i++) if (skip.has(c.children[i].id)) adj--;
  return { parent: c.id, index: adj, line: [apply(c.ctm, a[0], a[1]), apply(c.ctm, b[0], b[1])] };
}

/** Arrow keys: the selection moves by `dx`, `dy` (one step); a layer in an auto
 * layout's flow moves one place along it instead. */
export function nudge(sel: Geo[], dx: number, dy: number): void {
  const list = movable(sel);
  if (!list.length) return;
  const changes: unknown[] = [];
  for (const g of list) {
    if (g.playout && !g.absolute) {
      const c = childrenOf(g.parent);
      if (!c) continue;
      const vertical = g.playout.mode === "vertical";
      const step = vertical ? Math.sign(dy) : Math.sign(dx);
      if (!step) continue;
      const i = c.children.findIndex((k) => k.id === g.id);
      const to = Math.max(0, Math.min(c.children.length - 1, i + step));
      if (to !== i) changes.push({ op: "move", node: g.id, parent: g.parent, index: to });
      continue;
    }
    const ctm: Aff = mul(translate(dx, dy), g.ctm);
    changes.push({ op: "set", node: g.id, props: { transform: clean(mul(inv(g.pctm), ctm)) } });
  }
  apply_(changes);
}

/** A subtree's JSON with new ids: nodes outside instances get fresh ones; an instance's
 * content keeps its paths under the copy's id (`I<copy>;<path>`). */
export function renumber(node: Record<string, unknown>, prefix?: { from: string; to: string }): Record<string, unknown> {
  const out: Record<string, unknown> = { ...node };
  const id = node.id as string;
  if (prefix && id.startsWith(prefix.from)) out.id = prefix.to + id.slice(prefix.from.length);
  else out.id = newId();
  let inner = prefix;
  if (node.type === "instance" && !prefix) inner = { from: `I${id};`, to: `I${out.id as string};` };
  const kids = node.children as Record<string, unknown>[] | undefined;
  if (Array.isArray(kids)) out.children = kids.map((k) => renumber(k, inner));
  return out;
}
