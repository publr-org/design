// What the panels, the keys and the menus do to the document: each control's change as
// Pubd changes (engine/src/edit/change.zig) applied through the viewer's editing
// (viewer/edit.ts), one undo step per action. A scrub or a drag is one step: `begin`
// when it starts, the changes as it moves, `commit` when it ends (`cancel` on Escape).
// The store follows every change itself (store.ts `docChanged`).

import { viewerEditing } from "../viewer/Viewer.ptsx";
import { feedOf } from "../viewer/feed";
import { childrenOf, F, listedFirst, liveEngine, typeOf } from "./doc";
import type { NodeInfo } from "./doc";
import {
  canvasRotation,
  clearSelection,
  currentPageId,
  currentTree,
  select,
  selectedInfos,
  selectionBox,
  shell,
  showMain,
} from "./store";

type Props = Record<string, unknown>;
type Change = Record<string, unknown>;
type Matrix = number[];

/** How a number field's value arrives: typed (`set`), or a scrub's start, moves, end. */
export type Phase = "set" | "start" | "move" | "end" | "cancel";

const ID: Matrix = [1, 0, 0, 1, 0, 0];

// ------------------------------------------------------------ applying

function editing() {
  const ed = viewerEditing();
  return ed?.engine ? ed : null;
}

let stepOpen = false;

/** Applies `changes` (one step, or inside the open one); false when refused. */
export function apply(changes: Change[]): boolean {
  if (!changes.length) return false;
  const ed = editing();
  if (!ed) return false;
  try {
    ed.edit(changes);
    return true;
  } catch (err) {
    console.error("edit", err);
    return false;
  }
}

export function begin(): void {
  const ed = editing();
  if (!ed || stepOpen) return;
  try {
    ed.begin();
    stepOpen = true;
  } catch (err) {
    console.error("begin", err);
  }
}

export function commit(): void {
  const ed = editing();
  if (!ed || !stepOpen) return;
  stepOpen = false;
  try {
    ed.commit();
  } catch (err) {
    console.error("commit", err);
  }
}

export function cancel(): void {
  const ed = editing();
  if (!ed || !stepOpen) return;
  stepOpen = false;
  try {
    ed.cancel();
  } catch (err) {
    console.error("cancel", err);
  }
}

/** A number field's handler: `changes(v)` for the value, as one step per typing and
 * one per scrub. */
export function numberEdit(changes: (v: number) => Change[]): (v: number, phase: Phase) => void {
  return (v: number, phase: Phase) => {
    if (phase === "start") begin();
    else if (phase === "end") commit();
    else if (phase === "cancel") cancel();
    else apply(changes(v));
  };
}

/** A step that runs several calls (an insert whose new id the next call needs). */
function inStep(fn: () => void): void {
  const ed = editing();
  if (!ed) return;
  const own = !stepOpen;
  if (own) begin();
  try {
    fn();
  } catch (err) {
    console.error("edit", err);
    if (own) {
      cancel();
      return;
    }
  }
  if (own) commit();
}

/** The ids the last call inserted (in order). */
function inserted(): string[] {
  const out = viewerEditing()?.last?.changes ?? [];
  const ids: string[] = [];
  for (const c of out) {
    const ch = c.change as { op: string; node?: { id?: string } };
    if (ch.op === "insert" && ch.node && typeof ch.node === "object" && ch.node.id) ids.push(ch.node.id);
  }
  return ids;
}

const set = (id: string, props: Props): Change => ({ op: "set", node: id, props });

/** One set a selected node, from what the Design tab read of it (null: leave it). */
function eachSet(fn: (info: NodeInfo) => Props | null): Change[] {
  const out: Change[] = [];
  for (const info of selectedInfos()) {
    const p = fn(info);
    if (p && Object.keys(p).length) out.push(set(info.node.id, p));
  }
  return out;
}

/** Sets `props` on every selected node (one step). */
export function setAll(props: Props): void {
  apply(eachSet(() => props));
}

// ------------------------------------------------------------ geometry

const xfOf = (info: NodeInfo): Matrix => ((info.node.transform as Matrix | undefined) ?? ID).slice();
const sizeOf = (info: NodeInfo): number[] => ((info.node.size as number[] | undefined) ?? [0, 0]).slice();

function invLinear(m: Matrix): Matrix {
  const det = m[0] * m[3] - m[1] * m[2] || 1;
  return [m[3] / det, -m[1] / det, -m[2] / det, m[0] / det];
}

/** The absolute transform of the parent of node `id` (the tree's), identity on the page. */
function parentXf(id: string): Matrix {
  const t = currentTree();
  const i = t.index.get(id);
  if (i === undefined) return ID;
  const p = t.parent[i];
  return p < 0 ? ID : Array.from(t.xf.subarray(p * 6, p * 6 + 6));
}

/** X typed: each selected layer at that X in its parent (Figma's Position fields). */
export const setX = numberEdit((v) =>
  selectedInfos().map((info) => {
    const m = xfOf(info);
    m[4] = v;
    return set(info.node.id, { transform: m });
  }),
);

export const setY = numberEdit((v) =>
  selectedInfos().map((info) => {
    const m = xfOf(info);
    m[5] = v;
    return set(info.node.id, { transform: m });
  }),
);

/** Width or height `v` for each selected node (the other follows with constrain
 * proportions; text that sized itself keeps the size typed). */
function resize(axis: 0 | 1, v: number): Change[] {
  if (!(v >= 0.01)) v = 0.01;
  return eachSet((info) => {
    const type = info.node.type;
    if (type === "group") return null;
    if (type === "line" && axis === 1) return null;
    const size = sizeOf(info);
    const was = size[axis];
    size[axis] = v;
    if (shell.constrain && was > 0) size[1 - axis] = (size[1 - axis] * v) / was;
    const p: Props = { size };
    if (type === "text") {
      const r = String(info.node.resize ?? "fixed");
      if (axis === 0 && r === "width-and-height") p.resize = "height";
      if (axis === 1 && r !== "fixed") p.resize = "fixed";
    }
    const layout = info.node.layout as Props | undefined;
    const key = axis === 0 ? "width" : "height";
    if (layout && layout[key] === "hug") p.layout = { ...layout, [key]: "fixed" };
    const sizing = info.node.sizing as Props | undefined;
    const sk = axis === 0 ? "w" : "h";
    if (sizing && sizing[sk] && sizing[sk] !== "fixed") p.sizing = { ...sizing, [sk]: "fixed" };
    return p;
  });
}

export const setW = numberEdit((v) => resize(0, v));
export const setH = numberEdit((v) => resize(1, v));

/** The transform turned or mirrored about the box's centre. */
function aboutCentre(info: NodeInfo, linear: (m: Matrix) => Matrix): Matrix {
  const m = xfOf(info);
  const [w, h] = sizeOf(info);
  const cx = m[0] * (w / 2) + m[2] * (h / 2) + m[4];
  const cy = m[1] * (w / 2) + m[3] * (h / 2) + m[5];
  const l = linear(m);
  return [l[0], l[1], l[2], l[3], cx - (l[0] * (w / 2) + l[2] * (h / 2)), cy - (l[1] * (w / 2) + l[3] * (h / 2))];
}

const rotate = (m: Matrix, rad: number): Matrix => {
  const c = Math.cos(rad);
  const s = Math.sin(rad);
  return [c * m[0] - s * m[1], s * m[0] + c * m[1], c * m[2] - s * m[3], s * m[2] + c * m[3]];
};

/** The rotation the panel shows (degrees, counterclockwise). */
export const rotationOf = (m: Matrix) => (Math.atan2(-m[1], m[0]) * 180) / Math.PI;

/** Rotation typed: the layer turned about its centre until it shows `v` on the canvas
 * (the field shows the canvas rotation, ancestors' included). */
export const setRotation = numberEdit((v) =>
  eachSet((info) => {
    const now = canvasRotation(info.node.id) ?? rotationOf(xfOf(info));
    const d = (-(v - now) * Math.PI) / 180;
    return { transform: aboutCentre(info, (m) => rotate(m, d)) };
  }),
);

export function rotate90(): void {
  apply(eachSet((info) => ({ transform: aboutCentre(info, (m) => rotate(m, -Math.PI / 2)) })));
}

export function flip(axis: "h" | "v"): void {
  apply(eachSet((info) => ({ transform: aboutCentre(info, (m) => (axis === "h" ? [-m[0], -m[1], m[2], m[3]] : [m[0], m[1], -m[2], -m[3]])) })));
}

/** Aligns the selection: one layer in its parent, several to their box. */
export function align(how: "left" | "center" | "right" | "top" | "middle" | "bottom"): void {
  const t = currentTree();
  const infos = selectedInfos();
  if (!infos.length) return;
  let box: number[] | null;
  if (infos.length === 1) {
    const i = t.index.get(infos[0].node.id);
    const p = i === undefined ? -1 : t.parent[i];
    if (p < 0) return;
    const m = Array.from(t.xf.subarray(p * 6, p * 6 + 6));
    const w = t.size[p * 2];
    const h = t.size[p * 2 + 1];
    box = [m[4], m[5], m[4] + m[0] * w + m[2] * h, m[5] + m[1] * w + m[3] * h];
  } else box = selectionBox();
  if (!box) return;
  const out: Change[] = [];
  for (const info of infos) {
    const i = t.index.get(info.node.id);
    if (i === undefined) continue;
    const c = Array.from(t.xf.subarray(i * 6, i * 6 + 6));
    const w = t.size[i * 2];
    const h = t.size[i * 2 + 1];
    const xs = [c[4], c[4] + c[0] * w, c[4] + c[2] * h, c[4] + c[0] * w + c[2] * h];
    const ys = [c[5], c[5] + c[1] * w, c[5] + c[3] * h, c[5] + c[1] * w + c[3] * h];
    const a = [Math.min(...xs), Math.min(...ys), Math.max(...xs), Math.max(...ys)];
    let dx = 0;
    let dy = 0;
    if (how === "left") dx = box[0] - a[0];
    if (how === "right") dx = box[2] - a[2];
    if (how === "center") dx = (box[0] + box[2]) / 2 - (a[0] + a[2]) / 2;
    if (how === "top") dy = box[1] - a[1];
    if (how === "bottom") dy = box[3] - a[3];
    if (how === "middle") dy = (box[1] + box[3]) / 2 - (a[1] + a[3]) / 2;
    if (Math.abs(dx) < 1e-6 && Math.abs(dy) < 1e-6) continue;
    const inv = invLinear(parentXf(info.node.id));
    const m = xfOf(info);
    m[4] += inv[0] * dx + inv[2] * dy;
    m[5] += inv[1] * dx + inv[3] * dy;
    out.push(set(info.node.id, { transform: m }));
  }
  apply(out);
}

export function setConstraint(axis: "h" | "v", value: string): void {
  apply(eachSet((info) => ({ constraints: { ...((info.node.constraints as Props | undefined) ?? {}), [axis]: value } })));
}

/** Fixed, hug or fill for the width (`w`) or height (`h`). */
export function setSizing(axis: "w" | "h", mode: "fixed" | "hug" | "fill"): void {
  apply(
    eachSet((info) => {
      const p: Props = {};
      const key = axis === "w" ? "width" : "height";
      const layout = info.node.layout as Props | undefined;
      const inFlow = !!info.parent?.layout && info.node.absolute !== true;
      if (info.node.type === "text") {
        const r = String(info.node.resize ?? "fixed");
        if (mode === "hug") p.resize = axis === "w" ? "width-and-height" : r === "width-and-height" ? r : "height";
        else if (mode === "fixed") p.resize = axis === "w" ? (r === "width-and-height" ? "height" : r) : "fixed";
      } else if (layout) p.layout = { ...layout, [key]: mode === "hug" ? "hug" : "fixed" };
      if (inFlow) p.sizing = { ...((info.node.sizing as Props | undefined) ?? {}), [axis]: mode };
      return p;
    }),
  );
}

// ------------------------------------------------------------ auto layout

/** Auto layout on each selected frame (its direction and spacing read from how its
 * children lie), or a new auto layout frame around the selection. */
export function addAutoLayout(): void {
  const infos = selectedInfos();
  if (!infos.length) return;
  const frames = infos.filter((i) => ["frame", "component", "instance"].includes(i.node.type) && !i.node.layout);
  if (frames.length !== infos.length) {
    wrap("frame", true);
    return;
  }
  const t = currentTree();
  apply(
    frames.map((info) => {
      const i = t.index.get(info.node.id);
      const kids = i === undefined ? [] : childrenOf(t, i).map((c) => [t.xf[c * 6 + 4], t.xf[c * 6 + 5], t.size[c * 2], t.size[c * 2 + 1]]);
      return set(info.node.id, { layout: inferLayout(kids, i === undefined ? [0, 0, 0, 0] : [t.xf[i * 6 + 4], t.xf[i * 6 + 5], t.size[i * 2], t.size[i * 2 + 1]]) });
    }),
  );
}

/** A layout for children at page boxes `kids` ([x, y, w, h]) in a frame at `f`. */
function inferLayout(kids: number[][], f: number[]): Props {
  if (!kids.length) return { mode: "vertical", gap: 10, padding: [10, 10, 10, 10], width: "hug", height: "hug" };
  const x0 = Math.min(...kids.map((k) => k[0]));
  const y0 = Math.min(...kids.map((k) => k[1]));
  const x1 = Math.max(...kids.map((k) => k[0] + k[2]));
  const y1 = Math.max(...kids.map((k) => k[1] + k[3]));
  const spreadX = x1 - x0 - Math.max(...kids.map((k) => k[2]));
  const spreadY = y1 - y0 - Math.max(...kids.map((k) => k[3]));
  const horizontal = spreadX > spreadY;
  const sorted = [...kids].sort((a, b) => (horizontal ? a[0] - b[0] : a[1] - b[1]));
  let gap = 0;
  for (let k = 1; k < sorted.length; k++) gap += horizontal ? sorted[k][0] - (sorted[k - 1][0] + sorted[k - 1][2]) : sorted[k][1] - (sorted[k - 1][1] + sorted[k - 1][3]);
  gap = sorted.length > 1 ? Math.max(0, Math.round(gap / (sorted.length - 1))) : 10;
  const r = (v: number) => Math.max(0, Math.round(v));
  return { mode: horizontal ? "horizontal" : "vertical", gap, padding: [r(y0 - f[1]), r(f[0] + f[2] - x1), r(f[1] + f[3] - y1), r(x0 - f[0])], width: "hug", height: "hug" };
}

export function removeAutoLayout(): void {
  apply(eachSet((info) => (info.node.layout ? { layout: null } : null)));
}

/** Freeform (no auto layout), vertical, horizontal or grid. */
export function setFlow(mode: string): void {
  if (mode === "free") {
    removeAutoLayout();
    return;
  }
  const infos = selectedInfos();
  if (infos.some((i) => !i.node.layout)) {
    addAutoLayout();
    if (mode === "vertical") return;
  }
  apply(eachSet((info) => ({ layout: { ...((info.node.layout as Props | undefined) ?? {}), mode, ...(mode === "grid" && !(info.node.layout as Props | undefined)?.columns ? { columns: [{ type: "flex", value: 1 }, { type: "flex", value: 1 }], rows: [{ type: "flex", value: 1 }] } : {}) } })));
}

/** Sets layout keys on every selected auto layout frame. */
export function setLayout(patch: Props): void {
  apply(eachSet((info) => (info.node.layout ? { layout: { ...(info.node.layout as Props), ...patch } } : null)));
}

export const setGap = numberEdit((v) => eachSet((info) => (info.node.layout ? { layout: { ...(info.node.layout as Props), gap: Math.max(0, v), main: (info.node.layout as Props).main === "space-between" ? "start" : (info.node.layout as Props).main } } : null)));
export const setCrossGap = numberEdit((v) => eachSet((info) => (info.node.layout ? { layout: { ...(info.node.layout as Props), crossGap: Math.max(0, v) } } : null)));

/** Padding sides by index (top, right, bottom, left). */
export function padEdit(sides: number[]): (v: number, phase: Phase) => void {
  return numberEdit((v) =>
    eachSet((info) => {
      const l = info.node.layout as Props | undefined;
      if (!l) return null;
      const pad = ((l.padding as number[] | undefined) ?? [0, 0, 0, 0]).slice();
      for (const s of sides) pad[s] = Math.max(0, v);
      return { layout: { ...l, padding: pad } };
    }),
  );
}

/** The alignment box: column `c` and row `r` (0..2) as main and cross alignment. */
export function setAlignCell(c: number, r: number): void {
  const names = ["start", "center", "end"];
  apply(
    eachSet((info) => {
      const l = info.node.layout as Props | undefined;
      if (!l) return null;
      const horizontal = l.mode !== "vertical";
      const between = l.main === "space-between";
      return { layout: { ...l, main: between ? l.main : names[horizontal ? c : r], cross: names[horizontal ? r : c] } };
    }),
  );
}

// ------------------------------------------------------------ appearance

export const setOpacity = numberEdit((v) => eachSet(() => ({ opacity: Math.max(0, Math.min(100, v)) / 100 })));

export function radiusEdit(corner: number): (v: number, phase: Phase) => void {
  return numberEdit((v) =>
    eachSet((info) => {
      const r = info.node.radius;
      const now = Array.isArray(r) ? (r as number[]).slice() : [Number(r ?? 0), Number(r ?? 0), Number(r ?? 0), Number(r ?? 0)];
      const x = Math.max(0, v);
      if (corner < 0) return { radius: x };
      now[corner] = x;
      return { radius: now.every((k) => k === now[0]) ? now[0] : now };
    }),
  );
}

export function toggleVisible(): void {
  const infos = selectedInfos();
  const hide = infos.some((i) => i.node.visible !== false);
  setAll({ visible: !hide });
}

export function toggleLocked(): void {
  const infos = selectedInfos();
  const lock = infos.some((i) => i.node.locked !== true);
  setAll({ locked: lock });
  if (lock) clearSelection();
}

export function setVisibleOf(id: string, visible: boolean): void {
  apply([set(id, { visible })]);
}

export function setLockedOf(id: string, locked: boolean): void {
  apply([set(id, { locked })]);
}

export function renameLayer(id: string, name: string): void {
  apply([set(id, { name })]);
}

// ------------------------------------------------------------ fill, stroke, effects

export type Paint = Record<string, unknown> & { type: string };
export type PaintList = "fills" | "strokes";

/** The selected node's paints in panel order: the top-most first. */
export function panelPaints(which: PaintList): Paint[] {
  const first = selectedInfos()[0];
  const list = ((first?.node[which] as Paint[] | undefined) ?? []).slice();
  return list.reverse();
}

/** Sets the paints (panel order, the top-most first) on every selected node. */
export function setPanelPaints(which: PaintList, list: Paint[]): Change[] {
  const paints = list.slice().reverse();
  return eachSet((info) => {
    const p: Props = { [which]: paints };
    const styles = info.node.styles as Props | undefined;
    // A changed paint no longer follows the style it came from.
    const key = which === "fills" ? "fill" : "stroke";
    if (styles && key in styles) {
      const rest = { ...styles };
      delete rest[key];
      p.styles = rest;
    }
    if (which === "strokes" && list.length && !info.node.strokes) p.stroke = { ...((info.node.stroke as Props | undefined) ?? {}), weight: (info.node.stroke as Props | undefined)?.weight ?? 1 };
    return p;
  });
}

export function addPaint(which: PaintList): void {
  const list = panelPaints(which);
  list.unshift({ type: "solid", color: which === "fills" ? "#d9d9d9" : "#000000" });
  apply(setPanelPaints(which, list));
}

export function removePaint(which: PaintList, k: number): void {
  const list = panelPaints(which);
  list.splice(k, 1);
  apply(setPanelPaints(which, list));
}

export function togglePaint(which: PaintList, k: number): void {
  const list = panelPaints(which);
  if (!list[k]) return;
  list[k] = { ...list[k], visible: list[k].visible === false };
  apply(setPanelPaints(which, list));
}

/** Moves paint `from` to `to` (panel order). */
export function movePaint(which: PaintList, from: number, to: number): void {
  const list = panelPaints(which);
  if (from === to || !list[from]) return;
  const [p] = list.splice(from, 1);
  list.splice(Math.min(to, list.length), 0, p);
  apply(setPanelPaints(which, list));
}

/** Paint `k` changed by `patch` (in the open step during a drag). */
export function patchPaint(which: PaintList, k: number, patch: Props): void {
  const list = panelPaints(which);
  if (!list[k]) return;
  list[k] = { ...list[k], ...patch } as Paint;
  apply(setPanelPaints(which, list));
}

/** Paint `k`'s whole value replaced (a type change). */
export function replacePaint(which: PaintList, k: number, paint: Paint): void {
  const list = panelPaints(which);
  if (!list[k]) return;
  list[k] = paint;
  apply(setPanelPaints(which, list));
}

/** A hex the person typed ("f00", "FF0000", "#ff0000"): "#rrggbb", or null. */
export function parseHex(text: string): string | null {
  let h = text.trim().replace(/^#/, "");
  if (/^[0-9a-f]{3}$/i.test(h)) h = h.replace(/./g, (c) => c + c);
  if (/^[0-9a-f]{1,2}$/i.test(h)) h = h.padStart(2, h).repeat(3).slice(0, 6);
  return /^[0-9a-f]{6}$/i.test(h) ? `#${h.toLowerCase()}` : null;
}

/** A solid paint's colour from a typed hex (its alpha kept in the paint's opacity). */
export function setPaintHex(which: PaintList, k: number, text: string): void {
  const hex = parseHex(text);
  if (!hex) return;
  patchPaint(which, k, { color: hex });
}

export function paintOpacityEdit(which: PaintList, k: number): (v: number, phase: Phase) => void {
  return numberEdit((v) => {
    const list = panelPaints(which);
    const p = list[k];
    if (!p) return [];
    const patch: Props = { opacity: Math.max(0, Math.min(100, v)) / 100 };
    // The colour's own alpha goes into the paint's opacity (the field shows both).
    if (p.type === "solid" && typeof p.color === "string" && p.color.length === 9) patch.color = p.color.slice(0, 7);
    if (p.type === "solid" && Array.isArray(p.color)) patch.color = (p.color as number[]).slice(0, 3);
    list[k] = { ...p, ...patch } as Paint;
    return setPanelPaints(which, list);
  });
}

export const strokeWeight = numberEdit((v) => eachSet((info) => ({ stroke: { ...((info.node.stroke as Props | undefined) ?? {}), weight: Math.max(0, v) } })));

export function setStroke(patch: Props): void {
  apply(
    eachSet((info) => {
      const s = { ...((info.node.stroke as Props | undefined) ?? {}), ...patch };
      for (const k of Object.keys(patch)) if (patch[k] === null) delete s[k];
      delete s.outline;
      return { stroke: s };
    }),
  );
}

export function strokeSideEdit(side: number): (v: number, phase: Phase) => void {
  return numberEdit((v) =>
    eachSet((info) => {
      const s = (info.node.stroke as Props | undefined) ?? {};
      const w = Number(s.weight ?? 1);
      const sides = ((s.sides as number[] | undefined) ?? [w, w, w, w]).slice();
      sides[side] = Math.max(0, v);
      const st = { ...s, sides };
      delete st.outline;
      return { stroke: st };
    }),
  );
}

/** Stroke sides: all, one side, or custom (each side its own weight). */
export function setStrokeSides(which: "all" | "top" | "right" | "bottom" | "left" | "custom"): void {
  apply(
    eachSet((info) => {
      const s = { ...((info.node.stroke as Props | undefined) ?? {}) };
      const w = Number(s.weight ?? 1);
      delete s.outline;
      if (which === "all") delete s.sides;
      else if (which === "custom") s.sides = (s.sides as number[] | undefined) ?? [w, w, w, w];
      else s.sides = ["top", "right", "bottom", "left"].map((k) => (k === which ? w : 0));
      return { stroke: s };
    }),
  );
}

export type Effect = Record<string, unknown> & { type: string };

export function effectsOf(): Effect[] {
  return (((selectedInfos()[0]?.node.effects as Effect[] | undefined) ?? []) as Effect[]).slice();
}

export function setEffects(list: Effect[]): Change[] {
  return eachSet((info) => {
    const p: Props = { effects: list };
    const styles = info.node.styles as Props | undefined;
    if (styles && "effect" in styles) {
      const rest = { ...styles };
      delete rest.effect;
      p.styles = rest;
    }
    return p;
  });
}

export const EFFECT_DEFAULTS: Record<string, Effect> = {
  "drop-shadow": { type: "drop-shadow", color: "#00000040", offset: [0, 4], radius: 4, spread: 0 },
  "inner-shadow": { type: "inner-shadow", color: "#00000040", offset: [0, 4], radius: 4, spread: 0 },
  "layer-blur": { type: "layer-blur", radius: 4 },
  "background-blur": { type: "background-blur", radius: 4 },
};

export function addEffect(): void {
  const list = effectsOf();
  list.push({ ...EFFECT_DEFAULTS["drop-shadow"] });
  apply(setEffects(list));
}

/** Detaches the selected layers from their `kind` style ("fill", "stroke", "effect",
 * "text", "grid"): the values stay, the link goes. */
export function detachStyle(kind: string): void {
  apply(
    eachSet((info) => {
      const own = { ...((info.node.styles as Record<string, string> | undefined) ?? {}) };
      if (!(kind in own)) return null;
      delete own[kind];
      return { styles: Object.keys(own).length ? own : null };
    }),
  );
}

/** Removes every effect and the effect style with them. */
export function removeEffects(): void {
  apply(
    eachSet((info) => {
      const own = { ...((info.node.styles as Record<string, string> | undefined) ?? {}) };
      delete own.effect;
      return { effects: null, styles: Object.keys(own).length ? own : null };
    }),
  );
}

export function removeEffect(k: number): void {
  const list = effectsOf();
  list.splice(k, 1);
  apply(setEffects(list));
}

export function toggleEffect(k: number): void {
  const list = effectsOf();
  if (!list[k]) return;
  list[k] = { ...list[k], visible: list[k].visible === false };
  apply(setEffects(list));
}

export function setEffectType(k: number, type: string): void {
  const list = effectsOf();
  if (!list[k] || list[k].type === type) return;
  const was = list[k];
  const next = { ...EFFECT_DEFAULTS[type] };
  if (was.radius !== undefined) next.radius = was.radius;
  if (was.visible === false) next.visible = false;
  if ("offset" in next && was.offset) next.offset = was.offset;
  if ("color" in next && was.color) next.color = was.color;
  list[k] = next;
  apply(setEffects(list));
}

export function patchEffect(k: number, patch: Props): void {
  const list = effectsOf();
  if (!list[k]) return;
  list[k] = { ...list[k], ...patch } as Effect;
  apply(setEffects(list));
}

/** An effect parameter: "x", "y" (offset), "radius", "spread". */
export function effectEdit(k: number, key: "x" | "y" | "radius" | "spread"): (v: number, phase: Phase) => void {
  return numberEdit((v) => {
    const list = effectsOf();
    const e = list[k];
    if (!e) return [];
    if (key === "x" || key === "y") {
      const o = ((e.offset as number[] | undefined) ?? [0, 0]).slice();
      o[key === "x" ? 0 : 1] = v;
      list[k] = { ...e, offset: o };
    } else list[k] = { ...e, [key]: key === "radius" ? Math.max(0, v) : v };
    return setEffects(list);
  });
}

// ------------------------------------------------------------ text

type Face = { family: string; style: string; weight: number; italic: boolean };
let faces: Face[] | null = null;

/** The faces text can be set in (the engine's fonts: the server's and the shared ones). */
export function fontFaces(): Face[] {
  if (!faces) {
    try {
      faces = liveEngine()?.fontFaces() ?? null;
    } catch {
      faces = null;
    }
  }
  return faces ?? [];
}

/** Fonts were added: read the list again. */
export function fontsChanged(): void {
  faces = null;
}

export function families(): string[] {
  return [...new Set(fontFaces().map((f) => f.family))].sort((a, b) => a.localeCompare(b));
}

const STYLE_ORDER = ["thin", "extralight", "light", "regular", "medium", "semibold", "bold", "extrabold", "black"];

export function stylesOf(family: string): Face[] {
  const list = fontFaces().filter((f) => f.family.toLowerCase() === family.toLowerCase());
  const seen = new Set<string>();
  return list
    .filter((f) => (seen.has(f.style) ? false : (seen.add(f.style), true)))
    .sort((a, b) => a.weight - b.weight || Number(a.italic) - Number(b.italic) || STYLE_ORDER.indexOf(a.style.toLowerCase()) - STYLE_ORDER.indexOf(b.style.toLowerCase()));
}

/** Whether the family and style are here to draw with. */
export function hasFace(family: string, style: string): boolean {
  return fontFaces().some((f) => f.family.toLowerCase() === family.toLowerCase() && f.style.toLowerCase() === style.toLowerCase());
}

/** Text style keys set on every selected text (the runs' own values of them dropped, as
 * a change to the whole layer). */
export function setTextStyle(patch: Props): void {
  apply(textStyleChanges(patch));
}

function textStyleChanges(patch: Props | ((style: Props) => Props)): Change[] {
  return eachSet((info) => {
    if (info.node.type !== "text") return null;
    const style = (info.node.style as Props | undefined) ?? { family: "Inter" };
    const p = typeof patch === "function" ? patch(style) : patch;
    const out: Props = { style: { ...style, ...p } };
    const runs = info.node.runs as { style?: Props }[] | undefined;
    if (runs?.length) {
      out.runs = runs.map((r) => {
        if (!r.style) return r;
        const st = { ...r.style };
        for (const k of Object.keys(p)) delete st[k];
        if (p.family !== undefined) for (const k of ["fontStyle", "weight", "italic"]) delete st[k];
        return { ...r, style: st };
      });
    }
    const styles = info.node.styles as Props | undefined;
    if (styles && "text" in styles) {
      const rest = { ...styles };
      delete rest.text;
      out.styles = rest;
    }
    return out;
  });
}

/** Family `family`, keeping the style when it has it, else the nearest weight. */
export function setFamily(family: string): void {
  apply(
    textStyleChanges((style) => {
      const list = stylesOf(family);
      const want = String(style.fontStyle ?? "Regular");
      const weight = Number(style.weight ?? 400);
      const italic = style.italic === true;
      const face = list.find((f) => f.style.toLowerCase() === want.toLowerCase()) ?? [...list].sort((a, b) => Math.abs(a.weight - weight) + (a.italic !== italic ? 1000 : 0) - (Math.abs(b.weight - weight) + (b.italic !== italic ? 1000 : 0)))[0];
      return face ? { family, fontStyle: face.style, weight: face.weight, italic: face.italic } : { family };
    }),
  );
}

export function setFontStyle(name: string): void {
  apply(
    textStyleChanges((style) => {
      const face = stylesOf(String(style.family ?? "")).find((f) => f.style === name);
      return face ? { fontStyle: face.style, weight: face.weight, italic: face.italic } : { fontStyle: name };
    }),
  );
}

export const setFontSize = numberEdit((v) => textStyleChanges({ size: Math.max(1, v) }));

/** Line height typed: "Auto", "120%" or pixels. */
export function setLineHeight(text: string): void {
  const t = text.trim().toLowerCase();
  if (t === "auto" || t === "") return setTextStyle({ lineHeight: "auto" });
  const n = Number.parseFloat(t);
  if (!Number.isFinite(n)) return;
  setTextStyle({ lineHeight: t.endsWith("%") ? { percent: n } : { px: n } });
}

/** Letter spacing typed: "2%" or pixels. */
export function setLetterSpacing(text: string): void {
  const t = text.trim();
  const n = Number.parseFloat(t);
  if (!Number.isFinite(n)) return;
  setTextStyle({ letterSpacing: t.endsWith("%") ? { percent: n } : n });
}

export function setTextAlign(align: string): void {
  setAll({ align });
}

export function setTextValign(valign: string): void {
  setAll({ valign });
}

export function setTextResize(resize: string): void {
  apply(eachSet((info) => (info.node.type === "text" ? { resize } : null)));
}

// ------------------------------------------------------------ instances and components

/** Reads the page component `id` is on, when it is not read yet: an edit that copies a
 * main into its instances needs the main's nodes. False when there is no such component. */
async function readComponentPage(id: string): Promise<boolean> {
  const e = liveEngine();
  const c = e?.component(id);
  if (!e || !c || c.pageIndex < 0) return false;
  await feedOf(e)?.page(c.pageIndex);
  return true;
}

export async function setProperty(prop: string, value: unknown): Promise<void> {
  const info = selectedInfos()[0];
  if (!info || info.node.type !== "instance") return;
  // A variant property switches to a sibling of the main: the set's page is read first.
  if (info.mainId) await readComponentPage(info.mainId);
  apply([{ op: "prop", node: info.node.id, prop, value }]);
}

export function resetOverrides(): void {
  apply(selectedInfos().filter((i) => i.node.type === "instance" || i.instance).map((i) => ({ op: "reset", node: i.node.type === "instance" ? i.node.id : i.instance!.id })));
}

export function detachInstance(): void {
  apply(selectedInfos().filter((i) => i.node.type === "instance").map((i) => ({ op: "detach", node: i.node.id })));
}

export async function swapInstance(component: string): Promise<void> {
  await readComponentPage(component);
  apply(eachSet((info) => (info.node.type === "instance" ? { component } : null)));
}

/** The selected instance, or the outermost instance the selected layer is in, and its
 * main component's id. */
function selectedInstance(): { id: string; main: string } | null {
  const info = selectedInfos()[0];
  if (!info) return null;
  if (info.node.type === "instance") return info.mainId ? { id: info.node.id, main: info.mainId } : null;
  const x = info.instance;
  if (!x) return null;
  // The engine names the main only while its page is open; the instance always does.
  let main = x.main ?? "";
  if (!main)
    try {
      const c = liveEngine()?.nodeInfo(x.id).node.component;
      main = typeof c === "string" ? c : "";
    } catch {
      main = "";
    }
  return main ? { id: x.id, main } : null;
}

/** Go to main component: the main on its page, on its own in the view, with a bar to
 * return to the instance. */
export async function goToMain(): Promise<void> {
  const x = selectedInstance();
  if (!x) return;
  const page = liveEngine()?.component(x.main)?.pageIndex ?? -1;
  if (page >= 0) showMain(x.id, x.main, page);
}

/** An instance's own keys that say where it sits, not what it is. */
const PLACEMENT = new Set(["transform", "size", "sizing", "constraints", "absolute", "cell"]);

/** Push changes to main component: what the instance overrides becomes the main's (and
 * so every instance's), and the instance follows the main again. One step. */
export async function pushToMain(): Promise<void> {
  const x = selectedInstance();
  const e = liveEngine();
  if (!x || !e) return;
  // The main's page is read first when it is not open (the main is changed there).
  if (!(await readComponentPage(x.main))) return;
  const changes: Change[] = [];
  const resets: Change[] = [];
  for (const o of pushable(x.id)) {
    // The node in the instance, and the same node in the main: a path through a nested
    // instance names that instance's copy (`I<nested>;<id>`).
    const here = o.path ? `I${x.id};${o.path}` : x.id;
    const there = o.path === "" ? x.main : o.path.includes(";") ? `I${o.path}` : o.path;
    let node: Record<string, unknown>;
    try {
      node = e.nodeInfo(here).node as Record<string, unknown>;
    } catch {
      continue;
    }
    const props: Props = {};
    for (const k of o.keys) props[k] = node[k] ?? null;
    changes.push(set(there, props));
    resets.push({ op: "reset", node: here, keys: o.keys });
  }
  if (!changes.length) return;
  // Then what was pushed follows the main again; the rest stays the instance's own.
  apply([...changes, ...resets]);
}

/** What instance `id` overrides that a push would give its main: by path below it ("" the
 * instance), the keys. Where the instance sits is its own: its size and place stay. */
function pushable(id: string): { path: string; keys: string[] }[] {
  let inst: Record<string, unknown>;
  try {
    inst = liveEngine()!.nodeInfo(id).node as Record<string, unknown>;
  } catch {
    return [];
  }
  return Object.entries((inst.overrides as Record<string, string[]> | undefined) ?? {})
    .map(([path, keys]) => ({ path, keys: path === "" ? keys.filter((k) => !PLACEMENT.has(k)) : keys }))
    .filter((o) => o.keys.length > 0);
}

/** Whether the selected instance (or the one the selected layer is in) changes anything
 * a push would give its main. */
export function canPushToMain(): boolean {
  const x = selectedInstance();
  return !!x && pushable(x.id).length > 0;
}

// ------------------------------------------------------------ the page

export function setPageBackground(hex: string): void {
  const id = currentPageId();
  if (id) apply([set(id, { background: hex })]);
}

// ------------------------------------------------------------ structure

/** Where layer `id` is: its parent's id (the page's for a top-level one) and its index
 * there (0 the bottom-most). */
function place(id: string): { parent: string; index: number; count: number } | null {
  const t = currentTree();
  const i = t.index.get(id);
  if (i === undefined) return null;
  const p = t.parent[i];
  const sibs = childrenOf(t, p);
  const at = sibs.indexOf(i);
  return { parent: p >= 0 ? t.ids[p] : currentPageId(), index: listedFirst(t, p) ? at : sibs.length - 1 - at, count: sibs.length };
}

/** The selection that may change structure: not inside instances, in panel order. */
function movable(): string[] {
  const t = currentTree();
  return shell.selection.filter((id) => {
    const i = t.index.get(id);
    return i !== undefined && !(t.flags[i] & F.inInstance);
  });
}

export function deleteSelection(): void {
  const ids = movable();
  if (!ids.length) return;
  // Inner layers of a deleted one go with it.
  const t = currentTree();
  const top = ids.filter((id) => !ids.some((o) => o !== id && t.index.get(id)! > t.index.get(o)! && t.index.get(id)! < t.end[t.index.get(o)!]));
  if (apply(top.map((id) => ({ op: "delete", node: id })))) clearSelection();
}

/** The layers' boxes in the parent's space: x0, y0, x1, y1. */
function boxIn(parentAbs: Matrix, ids: string[]): number[] {
  const t = currentTree();
  const inv = invLinear(parentAbs);
  const b = [Infinity, Infinity, -Infinity, -Infinity];
  for (const id of ids) {
    const i = t.index.get(id);
    if (i === undefined) continue;
    const m = t.xf.subarray(i * 6, i * 6 + 6);
    const w = t.size[i * 2];
    const h = t.size[i * 2 + 1];
    for (const [x, y] of [
      [0, 0],
      [w, 0],
      [0, h],
      [w, h],
    ]) {
      const px = m[0] * x + m[2] * y + m[4] - parentAbs[4];
      const py = m[1] * x + m[3] * y + m[5] - parentAbs[5];
      const lx = inv[0] * px + inv[2] * py;
      const ly = inv[1] * px + inv[3] * py;
      b[0] = Math.min(b[0], lx);
      b[1] = Math.min(b[1], ly);
      b[2] = Math.max(b[2], lx);
      b[3] = Math.max(b[3], ly);
    }
  }
  return b;
}

/** Wraps the selection in a new group, frame (auto layout: `auto`) or component. */
export function wrap(kind: "group" | "frame" | "component", auto = false): void {
  const ids = movable();
  if (!ids.length) return;
  const first = place(ids[0]);
  if (!first) return;
  const sameParent = ids.filter((id) => place(id)?.parent === first.parent);
  const pAbs = parentXf(sameParent[0]);
  const b = boxIn(pAbs, sameParent);
  const ordered = sameParent.map((id) => ({ id, at: place(id)!.index })).sort((a, c) => a.at - c.at);
  const topIndex = ordered[ordered.length - 1].at;
  const node: Props = { id: "", type: kind, name: kind === "group" ? "Group" : kind === "component" ? "Component" : "Frame", transform: [1, 0, 0, 1, b[0], b[1]], size: [b[2] - b[0], b[3] - b[1]] };
  if (kind === "frame") node.fills = auto ? [] : [{ type: "solid", color: "#ffffff" }];
  if (auto) node.layout = inferLayout([], [0, 0, 0, 0]);
  let made = "";
  inStep(() => {
    const ed = editing()!;
    ed.edit({ op: "insert", parent: first.parent, index: topIndex + 1, node });
    made = inserted()[0] ?? "";
    if (!made) throw new Error("the new layer has no id");
    const changes: Change[] = [];
    ordered.forEach((o, k) => {
      const info = selectedInfos().find((x) => x.node.id === o.id);
      const t = currentTree();
      const i = t.index.get(o.id)!;
      const m = info ? xfOf(info) : Array.from(t.xf.subarray(i * 6, i * 6 + 6));
      changes.push({ op: "move", node: o.id, parent: made, index: k });
      changes.push(set(o.id, { transform: [m[0], m[1], m[2], m[3], m[4] - b[0], m[5] - b[1]] }));
    });
    if (auto) {
      const kids = ordered.map((o) => {
        const t = currentTree();
        const i = t.index.get(o.id)!;
        return [t.xf[i * 6 + 4], t.xf[i * 6 + 5], t.size[i * 2], t.size[i * 2 + 1]];
      });
      changes.push(set(made, { layout: { ...inferLayout(kids, [kids.length ? Math.min(...kids.map((k) => k[0])) : 0, kids.length ? Math.min(...kids.map((k) => k[1])) : 0, b[2] - b[0], b[3] - b[1]]), padding: [0, 0, 0, 0] } }));
    }
    ed.edit(changes);
  });
  if (made) select([made]);
}

/** Group, frame or component children put back in the parent; the container goes. */
export function ungroup(): void {
  const t = currentTree();
  const targets = movable().filter((id) => {
    const i = t.index.get(id)!;
    const type = typeOf(t, i);
    return (type === "group" || type === "frame" || type === "boolean") && t.end[i] > i + 1;
  });
  if (!targets.length) return;
  const out: string[] = [];
  const changes: Change[] = [];
  for (const g of targets) {
    const at = place(g)!;
    const gi = t.index.get(g)!;
    const info = selectedInfos().find((x) => x.node.id === g);
    const gm = info ? xfOf(info) : ID;
    // Bottom-most first, each above the last.
    const kids = listedFirst(t, gi) ? childrenOf(t, gi) : childrenOf(t, gi).reverse();
    kids.forEach((c, k) => {
      const id = t.ids[c];
      const ci = liveEngine()?.nodeInfo(id);
      const m = ((ci?.node.transform as Matrix | undefined) ?? ID).slice();
      const nm = [gm[0] * m[0] + gm[2] * m[1], gm[1] * m[0] + gm[3] * m[1], gm[0] * m[2] + gm[2] * m[3], gm[1] * m[2] + gm[3] * m[3], gm[0] * m[4] + gm[2] * m[5] + gm[4], gm[1] * m[4] + gm[3] * m[5] + gm[5]];
      changes.push({ op: "move", node: id, parent: at.parent, index: at.index + 1 + k });
      changes.push(set(id, { transform: nm }));
      out.push(id);
    });
    changes.push({ op: "delete", node: g });
  }
  if (apply(changes)) select(out);
}

/** Makes a component: a selected frame becomes one, anything else is wrapped in one. */
export function createComponent(): void {
  const infos = selectedInfos();
  if (infos.length === 1 && infos[0].node.type === "frame" && !infos[0].instance) {
    apply([set(infos[0].node.id, { type: "component" })]);
    return;
  }
  wrap("component");
}

/** Bring forward (+1), send backward (-1), to the front (+Infinity), to the back. */
export function reorder(by: number): void {
  const ids = movable();
  const list = ids.map((id) => ({ id, at: place(id) })).filter((x) => x.at) as { id: string; at: { parent: string; index: number; count: number } }[];
  // Raised from the top down, lowered from the bottom up, so they keep their order.
  list.sort((a, b) => (by > 0 ? b.at.index - a.at.index : a.at.index - b.at.index));
  const changes: Change[] = [];
  const taken = new Map<string, number>();
  for (const x of list) {
    let to: number;
    if (by === Infinity) {
      const n = taken.get(x.at.parent) ?? 0;
      to = x.at.count - 1 - n;
      taken.set(x.at.parent, n + 1);
    } else if (by === -Infinity) {
      const n = taken.get(x.at.parent) ?? 0;
      to = n;
      taken.set(x.at.parent, n + 1);
    } else to = Math.max(0, Math.min(x.at.count - 1, x.at.index + by));
    if (to !== x.at.index) changes.push({ op: "move", node: x.id, parent: x.at.parent, index: to });
  }
  apply(changes);
}

/** Moves layer `id` into `parent` (id; "" the page) at `index` (0 the bottom-most),
 * keeping where it shows on the page. */
export function moveLayer(id: string, parent: string, index: number): void {
  const t = currentTree();
  const i = t.index.get(id);
  if (i === undefined) return;
  const pid = parent || currentPageId();
  const from = place(id);
  const changes: Change[] = [];
  const sameParent = from?.parent === pid;
  changes.push({ op: "move", node: id, parent: pid, index: sameParent && from && index > from.index ? index - 1 : index });
  if (!sameParent) {
    // The page transform kept: the new parent's inverse times the old absolute one.
    const abs = Array.from(t.xf.subarray(i * 6, i * 6 + 6));
    const pi = parent ? t.index.get(parent) : undefined;
    const pm = pi === undefined ? ID : Array.from(t.xf.subarray(pi * 6, pi * 6 + 6));
    const inv = invLinear(pm);
    const dx = abs[4] - pm[4];
    const dy = abs[5] - pm[5];
    changes.push(set(id, { transform: [inv[0] * abs[0] + inv[2] * abs[1], inv[1] * abs[0] + inv[3] * abs[1], inv[0] * abs[2] + inv[2] * abs[3], inv[1] * abs[2] + inv[3] * abs[3], inv[0] * dx + inv[2] * dy, inv[1] * dx + inv[3] * dy] }));
  }
  apply(changes);
}

// ------------------------------------------------------------ copy and paste

type Clip = { nodes: Record<string, unknown>[]; parent: string };
let clip: Clip | null = null;

export function copySelection(): void {
  const e = liveEngine();
  if (!e) return;
  const t = currentTree();
  const ids = [...shell.selection].sort((a, b) => (t.index.get(b) ?? 0) - (t.index.get(a) ?? 0));
  if (!ids.length) return;
  try {
    clip = { nodes: ids.map((id) => e.nodeJson(id)), parent: place(ids[0])?.parent ?? "" };
  } catch (err) {
    console.error("copy", err);
  }
}

export function cutSelection(): void {
  copySelection();
  deleteSelection();
}

export const canPaste = () => !!clip;

/** Pastes what was copied: into a selected frame, above a selected layer, or where it
 * was copied from. */
export function paste(): void {
  if (!clip) return;
  const t = currentTree();
  const sel = shell.selection;
  let parent = "";
  let index = -1;
  if (sel.length === 1) {
    const i = t.index.get(sel[0]);
    const type = i === undefined ? "" : typeOf(t, i);
    const copied = clip.nodes.some((n) => n.id === sel[0]);
    if (!copied && ["frame", "component", "group"].includes(type) && !(t.flags[i!] & F.inInstance)) {
      parent = sel[0];
      index = 1e9;
    } else {
      const at = place(sel[0]);
      if (at && !(t.flags[i!] & F.inInstance)) {
        parent = at.parent;
        index = at.index + 1;
      }
    }
  }
  if (!parent) {
    parent = t.index.has(clip.parent) || clip.parent === currentPageId() ? clip.parent : currentPageId();
    const p = t.index.get(parent);
    index = p === undefined ? 1e9 : 1e9;
  }
  const changes = clip.nodes.map((node, k) => ({ op: "insert", parent, index: index + k, node }));
  if (apply(changes)) select(inserted());
}

export function duplicate(): void {
  const e = liveEngine();
  if (!e) return;
  const ids = movable();
  const changes: Change[] = [];
  for (const id of ids) {
    const at = place(id);
    if (!at) continue;
    try {
      changes.push({ op: "insert", parent: at.parent, index: at.index + 1, node: e.nodeJson(id) });
    } catch (err) {
      console.error("duplicate", err);
    }
  }
  if (apply(changes)) select(inserted());
}

/** Cmd+A: the selection's siblings (the page's layers when nothing is selected). */
export function selectAll(): void {
  const t = currentTree();
  const i = shell.selection.length ? t.index.get(shell.selection[0]) : undefined;
  const p = i === undefined ? -1 : t.parent[i];
  select(childrenOf(t, p).map((c) => t.ids[c]));
}

/** The layers beside the selection that are not in it (Shift+Cmd+A). */
export function selectInverse(): void {
  const t = currentTree();
  const i = shell.selection.length ? t.index.get(shell.selection[0]) : undefined;
  const p = i === undefined ? -1 : t.parent[i];
  const picked = new Set(shell.selection);
  select(childrenOf(t, p).map((c) => t.ids[c]).filter((id) => !picked.has(id)));
}

// ------------------------------------------------------------ the main menu's own

/** Turns the selection `deg` degrees about its centre, counter-clockwise for positive
 * (the Design tab's rotation). */
export function rotateBy(deg: number): void {
  apply(eachSet((info) => ({ transform: aboutCentre(info, (m) => rotate(m, (-deg * Math.PI) / 180)) })));
}

/** The face of `family` nearest `weight` with italic `italic`, or null. */
function nearestFace(family: string, weight: number, italic: boolean): Face | null {
  const list = stylesOf(family);
  return [...list].sort((a, b) => Math.abs(a.weight - weight) + (a.italic !== italic ? 1000 : 0) - (Math.abs(b.weight - weight) + (b.italic !== italic ? 1000 : 0)))[0] ?? null;
}

/** Cmd+B: bold texts go back to regular, the rest go bold (the family's nearest faces). */
export function toggleBold(): void {
  apply(
    textStyleChanges((style) => {
      const bold = Number(style.weight ?? 400) >= 700;
      const face = nearestFace(String(style.family ?? ""), bold ? 400 : 700, style.italic === true);
      return face ? { fontStyle: face.style, weight: face.weight, italic: face.italic } : {};
    }),
  );
}

/** Cmd+I: italic texts go upright, the rest italic, when the family has the face. */
export function toggleItalic(): void {
  apply(
    textStyleChanges((style) => {
      const face = nearestFace(String(style.family ?? ""), Number(style.weight ?? 400), style.italic !== true);
      return face && face.italic !== (style.italic === true) ? { fontStyle: face.style, weight: face.weight, italic: face.italic } : {};
    }),
  );
}

/** Underline or strikethrough on, or off when the texts have it already. */
export function toggleDecoration(kind: "underline" | "strikethrough"): void {
  const now = shell.inspector?.typography?.decoration;
  setTextStyle({ decoration: now === kind ? "none" : kind });
}

/** The texts' font size `by` points bigger (or smaller, at least 1). */
export function adjustFontSize(by: number): void {
  apply(textStyleChanges((style) => ({ size: Math.max(1, Number(style.size ?? 12) + by) })));
}

/** No fills (or strokes) on the selection. */
export function removePaints(which: PaintList): void {
  apply(setPanelPaints(which, []));
}

/** Shift+X: each layer's fills become its strokes and its strokes its fills. */
export function swapFillStroke(): void {
  apply(
    eachSet((info) => {
      const fills = (info.node.fills as Paint[] | undefined) ?? [];
      const strokes = (info.node.strokes as Paint[] | undefined) ?? [];
      const p: Props = { fills: strokes, strokes: fills };
      if (fills.length && !info.node.stroke) p.stroke = { weight: 1 };
      const styles = info.node.styles as Props | undefined;
      if (styles && ("fill" in styles || "stroke" in styles)) {
        const rest = { ...styles };
        delete rest.fill;
        delete rest.stroke;
        if (styles.fill !== undefined) rest.stroke = styles.fill;
        if (styles.stroke !== undefined) rest.fill = styles.stroke;
        p.styles = rest;
      }
      return p;
    }),
  );
}
