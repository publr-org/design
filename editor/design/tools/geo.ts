// Geometry for the canvas's tools, and what they ask the engine on the canvas's thread
// (engine/src/edit/canvas.zig, text_edit.zig): where nodes are on their page, what they
// sit in, the frame a drag drops into. Page units throughout; transforms are
// [a, b, c, d, e, f] as Pubd writes them.
//
// Glue, not UI.

import type { Editing } from "../../viewer/edit";
import type { Engine } from "../../viewer/engine";
import { viewerEditing, viewerStage } from "../../viewer/Viewer.ptsx";

export type Aff = [number, number, number, number, number, number];
export type Pt = [number, number];
/** x0, y0, x1, y1. */
export type Box = [number, number, number, number];

export type AxisLayout = { mode: "horizontal" | "vertical" | "grid"; wrap: boolean; gap: number; padding: number[]; width: "fixed" | "hug"; height: "fixed" | "hug" };

/** A node as the tools read it (canvas.zig nodesJson). */
export type Geo = {
  id: string;
  type: string;
  name: string;
  parent: string;
  ptype: string;
  /** The ancestors, the top-level one first. */
  path: string[];
  page: number | null;
  ctm: Aff;
  pctm: Aff;
  transform: Aff;
  size: [number, number];
  visible: boolean;
  locked: boolean;
  inInstance: boolean;
  children: number;
  playout: AxisLayout | null;
  layout: AxisLayout | null;
  absolute: boolean;
  sizing: ["fixed" | "hug" | "fill", "fixed" | "hug" | "fill"];
  constraints: [string, string];
  resize?: "fixed" | "height" | "width-and-height" | "truncate";
  align?: "left" | "center" | "right" | "justify";
};

export type Child = { id: string; type: string; ctm: Aff; size: [number, number]; visible: boolean; locked: boolean; absolute: boolean };
export type Children = { id: string; type: string; ctm: Aff; size: [number, number]; layout: AxisLayout | null; children: Child[] };

export const IDENTITY: Aff = [1, 0, 0, 1, 0, 0];

/** `a` after `b` (apply `b` first). */
export function mul(a: Aff, b: Aff): Aff {
  return [a[0] * b[0] + a[2] * b[1], a[1] * b[0] + a[3] * b[1], a[0] * b[2] + a[2] * b[3], a[1] * b[2] + a[3] * b[3], a[0] * b[4] + a[2] * b[5] + a[4], a[1] * b[4] + a[3] * b[5] + a[5]];
}

export function inv(m: Aff): Aff {
  const det = m[0] * m[3] - m[1] * m[2] || 1e-12;
  const id = 1 / det;
  return [m[3] * id, -m[1] * id, -m[2] * id, m[0] * id, (m[2] * m[5] - m[3] * m[4]) * id, (m[1] * m[4] - m[0] * m[5]) * id];
}

export const apply = (m: Aff, x: number, y: number): Pt => [m[0] * x + m[2] * y + m[4], m[1] * x + m[3] * y + m[5]];
export const applyVec = (m: Aff, x: number, y: number): Pt => [m[0] * x + m[2] * y, m[1] * x + m[3] * y];
export const translate = (x: number, y: number): Aff => [1, 0, 0, 1, x, y];
export const scaling = (x: number, y: number): Aff => [x, 0, 0, y, 0, 0];
export function rotation(rad: number): Aff {
  const c = Math.cos(rad);
  const s = Math.sin(rad);
  return [c, s, -s, c, 0, 0];
}

/** Turned at all (not a multiple of 90° counts too, but not a flip). */
export const turned = (m: Aff) => Math.abs(m[1]) > 1e-6 || Math.abs(m[2]) > 1e-6;

/** The angle of a transform's x axis, radians. */
export const angleOf = (m: Aff) => Math.atan2(m[1], m[0]);

/** A box's corners on the page: top-left, top-right, bottom-right, bottom-left. */
export function corners(ctm: Aff, size: [number, number]): Pt[] {
  const [w, h] = size;
  return [apply(ctm, 0, 0), apply(ctm, w, 0), apply(ctm, w, h), apply(ctm, 0, h)];
}

export function aabbOf(ctm: Aff, size: [number, number]): Box {
  const c = corners(ctm, size);
  return [Math.min(...c.map((p) => p[0])), Math.min(...c.map((p) => p[1])), Math.max(...c.map((p) => p[0])), Math.max(...c.map((p) => p[1]))];
}

export function union(boxes: Box[]): Box | null {
  if (!boxes.length) return null;
  const b: Box = [Infinity, Infinity, -Infinity, -Infinity];
  for (const x of boxes) {
    b[0] = Math.min(b[0], x[0]);
    b[1] = Math.min(b[1], x[1]);
    b[2] = Math.max(b[2], x[2]);
    b[3] = Math.max(b[3], x[3]);
  }
  return b;
}

export const overlaps = (a: Box, b: Box) => a[0] <= b[2] && b[0] <= a[2] && a[1] <= b[3] && b[1] <= a[3];

/** Whether page point (x, y) lies in a node's (maybe turned) box. */
export function insideBox(ctm: Aff, size: [number, number], x: number, y: number): boolean {
  const [lx, ly] = apply(inv(ctm), x, y);
  return lx >= 0 && ly >= 0 && lx <= size[0] && ly <= size[1];
}

const round2 = (v: number) => Math.round(v * 100) / 100;
/** A transform with its numbers rounded off float noise (Pubd keeps what is given). */
export const clean = (m: Aff): Aff => [m[0], m[1], m[2], m[3], round2(m[4]), round2(m[5])].map((v, i) => (i < 4 ? Math.round(v * 1e6) / 1e6 : v)) as Aff;

// ------------------------------------------------------------ the engine

export function editing(): Editing | null {
  return viewerEditing();
}

/** The engine on the canvas's thread (null while no file is open for editing). */
export function engine(): Engine | null {
  return viewerEditing()?.engine ?? null;
}

export function pageIndex(): number {
  return viewerStage()?.page ?? 0;
}

/** Nodes `ids` as the tools read them (missing ones left out). */
export function geos(ids: string[]): Geo[] {
  const e = engine();
  if (!e || !ids.length) return [];
  try {
    return e.canvasNodes<Geo>(ids).filter((g): g is Geo => !!g);
  } catch (err) {
    console.error("canvas nodes", err);
    return [];
  }
}

export function geo(id: string): Geo | null {
  return geos([id])[0] ?? null;
}

/** The id of page `index` (its nodes' parent at the top). */
export function pageId(index = pageIndex()): string {
  return viewerStage()?.doc?.pages[index]?.id ?? "";
}

export function childrenOf(id: string): Children | null {
  const e = engine();
  if (!e || !id) return null;
  try {
    return e.canvasChildren<Children>(id);
  } catch {
    return null;
  }
}

/** The frame (or the page) a drop at page point (x, y) puts layers in. */
export function dropAt(x: number, y: number, exclude: string[]): { id: string; page: boolean } | null {
  const e = engine();
  if (!e) return null;
  try {
    return e.canvasDrop(pageIndex(), x, y, exclude);
  } catch {
    return null;
  }
}

/** What a click at (x, y) hits: the deepest node, or null. */
export function deepHit(x: number, y: number): string | null {
  const e = engine();
  if (!e) return null;
  const h = e.hitNode(pageIndex(), x, y, 0);
  return h ? h.id : null;
}

/** Applies changes (in the open step, or a step of their own). */
export function apply_(changes: unknown[]): void {
  const ed = editing();
  if (!ed || !changes.length) return;
  ed.edit(changes);
}

/** A new node id: `<seed>:<n>`, the seed this tab's own. */
const seed = 3_000_000_000 + Math.floor(Math.random() * 1_000_000_000);
let next = 1;
export const newId = () => `${seed}:${next++}`;
