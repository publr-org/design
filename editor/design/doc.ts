// The shell's one door to the document: the page's layer tree, a node's properties, hit
// testing, the styles and the local components. The tree, the nodes and the hit test
// are the live document: the engine on the canvas's thread, the one every edit goes
// through (viewer/edit.ts), so after an edit, undo or redo the panels read what the
// canvas draws in the same frame. The file's styles and its components on every page
// are read once from the file as opened (doc-worker.ts). Nothing here touches the DOM.

import type { Engine, NodeInfo as EngineNode } from "../viewer/engine";
import { feedOf } from "../viewer/feed";
import { Pool } from "../viewer/pool";
import { viewerEditing } from "../viewer/Viewer.ptsx";
import { F, TYPES } from "./doc-types";
import type { Source } from "./doc-types";

export { F, TYPES };
export type { Source };

/** A page's nodes, depth first and top-most first (the layers panel's order). Node `i`'s
 * subtree is `i + 1 .. end[i]`; its children are found by jumping `end`. */
export type Tree = {
  n: number;
  /** The engine page it is of. */
  page: number;
  ids: string[];
  names: string[];
  /** Index into TYPES. */
  types: Uint8Array;
  parent: Int32Array;
  depth: Uint16Array;
  end: Int32Array;
  flags: Uint16Array;
  /** Absolute transforms, six numbers a node (page space). */
  xf: Float32Array;
  /** Width and height a node. */
  size: Float32Array;
  /** What the node and its subtree may cover: x0, y0, x1, y1 a node. */
  sub: Float32Array;
  index: Map<string, number>;
  /** The file's styles (as opened). */
  styles: StyleInfo[];
  /** Layout guides (Pubd `grids`), by node index. */
  grids: [number, Grid[]][];
  /** The variable modes a layer sets itself ("Dark mode"), by node index: its badge. */
  modes: Map<number, string>;
};

/** A layout guide (Pubd Grid). */
export type Grid = { type: "columns" | "rows" | "grid"; count?: number; gutter?: number; offset?: number; size?: number; align?: string; color?: unknown; visible?: boolean };

export type PageInfo = { id: string; name: string; background: unknown };
/** `stored`: the file keeps the style's own value (imports made before it did show a swatch only where a layer uses the style). */
/** `effect`: an effect style's first effect type (its mark in the list). */
/** A style; `own` is false for a library's style or a deleted one (layers still name them,
 * the list of the file's styles leaves them out). */
export type StyleInfo = { id: string; type: string; name: string; detail: string; swatch: string; effect: string; stored: boolean; own: boolean };
export type DocInfo = { name: string; pages: PageInfo[]; styles: StyleInfo[] };
export type ComponentInfo = { id: string; name: string; page: number; set: string; kind: "component" | "set"; variants: number };

/** A component property as its main defines it (Pubd `properties`). */
export type PropDef = { id: string; name: string; type: "boolean" | "text" | "instance-swap" | "variant"; default: unknown; options?: unknown[] };

/** A node's own fields (Pubd keys) with what the panel needs around it. */
export type NodeInfo = {
  node: Record<string, unknown> & { id: string; type: string; name?: string };
  children: number;
  parent: { id: string; type: string; name: string; layout: Record<string, unknown> | null; size: number[] | null; transform: number[] | null } | null;
  /** The main component's name (instances; "" when it is not in the file or its page is
   * not open). */
  main: string | null;
  /** The main component's id (instances). */
  mainId: string;
  /** The names of the styles the node follows, by kind. */
  styleNames: Record<string, string>;
  /** Its place among its parent's children (0 is the bottom-most). */
  index: number;
  /** A layer inside an instance: the outermost instance, the layer's path in it and
   * what the instance overrides of it. */
  instance: EngineNode["instance"] | null;
  /** An instance: its main's properties (a variant's set's too). */
  props: PropDef[];
  /** An instance of a variant: the variant's values by property, from its name
   * ("Size=Large, State=Hover"). */
  variant: Record<string, string>;
};

export const EMPTY: Tree = {
  n: 0,
  page: -1,
  ids: [],
  names: [],
  types: new Uint8Array(0),
  parent: new Int32Array(0),
  depth: new Uint16Array(0),
  end: new Int32Array(0),
  flags: new Uint16Array(0),
  xf: new Float32Array(0),
  size: new Float32Array(0),
  sub: new Float32Array(0),
  index: new Map(),
  styles: [],
  grids: [],
  modes: new Map(),
};

let pool: Pool | null = null;
/** Bumped by every open: answers for an older file are dropped. */
let generation = 0;
let styles: StyleInfo[] = [];

function worker(): Pool {
  pool ??= new Pool(1, new URL("./doc-worker.js", import.meta.url));
  for (const s of pool.slots) s.ready = true;
  return pool;
}

const call = (msg: Record<string, unknown>) => {
  const p = worker();
  return p.call(p.slots[0], msg);
};

/** The engine every edit goes through (null until a file is open on the canvas). */
export function liveEngine(): Engine | null {
  return viewerEditing()?.engine ?? null;
}

/** Opens a file; null when another open overtook it. */
export async function openDoc(source: Source): Promise<DocInfo | null> {
  const mine = ++generation;
  held.clear();
  const r = await call({ type: "open", source });
  if (mine !== generation) return null;
  styles = r.styles as StyleInfo[];
  return { name: r.name as string, pages: r.pages as PageInfo[], styles };
}

export function closeDoc(): void {
  generation++;
  held.clear();
  if (pool) void call({ type: "close" }).catch(() => {});
}

/** Page `page`'s tree, once the engine has the page; null when another open or page
 * overtook it. */
export async function loadTree(page: number): Promise<Tree | null> {
  const mine = generation;
  const e = liveEngine();
  if (!e) return null;
  await feedOf(e)?.page(page);
  if (mine !== generation || liveEngine() !== e) return null;
  return treeNow(page);
}

/** Each page's ids, names and guides as last read, with their hash as the engine gives
 * it: a page shown again reads only its geometry when they are as they were. */
type Held = { hash: number; ids: string[]; names: string[]; grids: [number, Grid[]][]; modes: Map<number, string>; index: Map<string, number> };
const held = new Map<number, Held>();
const decoder = new TextDecoder();

/** Page `page`'s tree as the engine has it now (null when the page is not read yet).
 * `same`: the edits since the last read changed only geometry or paint (the ids, names
 * and guides are as they were: the engine neither writes nor hashes them). */
export function treeNow(page: number, same = false): Tree | null {
  const e = liveEngine();
  if (!e) return null;
  const f = e.pageFile(page);
  if (f.src && !f.loaded) return null;
  // Ids and names (the biggest part, to make and to read) come only when they changed: a
  // property's edit leaves them as they were.
  const had = held.get(page);
  const buf = e.pageTree(page, had?.hash ?? 0, same && !!had);
  const dv = new DataView(buf.buffer, buf.byteOffset, buf.byteLength);
  const n = dv.getUint32(0, true);
  const jl = dv.getUint32(4, true);
  const hash = dv.getUint32(8, true);
  let at = 12;
  const pad = () => (at = (at + 3) & ~3);
  const f32 = (count: number) => {
    const a = new Float32Array(buf.buffer, buf.byteOffset + at, count);
    at += count * 4;
    return a;
  };
  const i32 = (count: number) => {
    const a = new Int32Array(buf.buffer, buf.byteOffset + at, count);
    at += count * 4;
    return a;
  };
  const u16 = (count: number) => {
    const a = new Uint16Array(buf.buffer, buf.byteOffset + at, count);
    at += count * 2;
    pad();
    return a;
  };
  const xf = f32(n * 6);
  const size = f32(n * 2);
  const sub = f32(n * 4);
  const parent = i32(n);
  const end = i32(n);
  const depth = u16(n);
  const flags = u16(n);
  const types = new Uint8Array(buf.buffer, buf.byteOffset + at, n);
  at += n;
  pad();
  let h = had;
  if (!h || hash !== h.hash || jl > 0) {
    const j = JSON.parse(decoder.decode(buf.subarray(at, at + jl))) as { ids: string[]; names: string[]; grids: [number, Grid[]][]; modes?: [number, string][] };
    const index = new Map<string, number>();
    for (let i = 0; i < n; i++) index.set(j.ids[i], i);
    h = { hash, ids: j.ids, names: j.names, grids: j.grids, modes: new Map(j.modes ?? []), index };
    held.set(page, h);
  }
  return { n, page, ids: h.ids, names: h.names, types, parent, depth, end, flags, xf, size, sub, index: h.index, styles, grids: h.grids, modes: h.modes };
}

/** Node `id` as the Design tab reads it, or null when it is gone. */
export function nodeNow(id: string): NodeInfo | null {
  const e = liveEngine();
  if (!e) return null;
  let r: EngineNode;
  try {
    r = e.nodeInfo(id);
  } catch {
    return null;
  }
  const node = r.node as NodeInfo["node"];
  let parent: NodeInfo["parent"] = null;
  if (r.parent) {
    try {
      const p = e.nodeInfo(r.parent).node as Record<string, unknown>;
      parent = {
        id: r.parent,
        type: String(p.type),
        name: String(p.name ?? ""),
        layout: (p.layout as Record<string, unknown> | undefined) ?? null,
        size: (p.size as number[] | undefined) ?? null,
        transform: (p.transform as number[] | undefined) ?? null,
      };
    } catch {
      parent = null;
    }
  }
  const styleNames: Record<string, string> = {};
  for (const [k, v] of Object.entries((node.styles as Record<string, string> | undefined) ?? {})) styleNames[k] = styles.find((s) => s.id === v)?.name ?? "";
  let main: string | null = null;
  let mainId = "";
  const props: PropDef[] = [];
  const variant: Record<string, string> = {};
  if (node.type === "instance") {
    main = "";
    mainId = typeof node.component === "string" ? node.component : (r.component ?? "");
    // The document lists every component, so the main is known before its page is read.
    const m = mainId ? e.component(mainId) : null;
    if (m) {
      main = m.name;
      props.push(...(m.properties as PropDef[]));
      const set = m.set ? e.component(m.set) : null;
      if (set) {
        for (const part of m.name.split(",")) {
          const [k, v] = part.split("=").map((x) => x.trim());
          if (k && v !== undefined) variant[k] = v;
        }
        main = set.name;
        props.unshift(...(set.properties as PropDef[]).filter((p) => p.type === "variant"));
      }
    }
  }
  return { node, children: r.children, parent, main, mainId, styleNames, index: r.index ?? 0, instance: r.instance ?? null, props, variant };
}

/** The deepest layer at page point (x, y) on page `page` by its real shape (hidden and
 * locked layers skipped), `tol` page units of slack; "" for none. */
export function hitShape(page: number, x: number, y: number, tol: number): string {
  const e = liveEngine();
  if (!e) return "";
  try {
    return e.hitShape(page, x, y, tol) ?? "";
  } catch {
    return "";
  }
}

export async function nodeInfo(id: string): Promise<NodeInfo | null> {
  return nodeNow(id);
}

export async function listComponents(): Promise<ComponentInfo[]> {
  const r = await call({ type: "components" });
  return r.list as ComponentInfo[];
}

// ------------------------------------------------------------ reading the tree

export const typeOf = (t: Tree, i: number) => TYPES[t.types[i]] ?? "other";

/** The children of `i` (-1: the page's), top-most first. */
export function childrenOf(t: Tree, i: number): number[] {
  const out: number[] = [];
  let j = i < 0 ? 0 : i + 1;
  const stop = i < 0 ? t.n : t.end[i];
  while (j < stop) {
    out.push(j);
    j = t.end[j];
  }
  return out;
}

/** Whether `i`'s children are listed first at the top (an auto layout's, in flow order,
 * or a reversed stack's) rather than the last (the top-most) at the top. */
export function listedFirst(t: Tree, i: number): boolean {
  return i >= 0 && (t.flags[i] & (F.reverseZ | F.autoV | F.autoH | F.autoGrid)) !== 0;
}

/** `i` and its ancestors, the top-level one first. */
export function pathOf(t: Tree, i: number): number[] {
  const out: number[] = [];
  for (let k = i; k >= 0; k = t.parent[k]) out.push(k);
  return out.reverse();
}

/** Whether `a` is `b` or inside it. */
export const within = (t: Tree, a: number, b: number) => a >= b && a < t.end[b];

const CONTAINERS = new Set(["frame", "group", "section", "component", "component-set", "instance", "boolean", "page"]);
export const isContainer = (t: Tree, i: number) => CONTAINERS.has(typeOf(t, i));

/** The node's box corners on the page (top-left, top-right, bottom-right, bottom-left). */
export function corners(t: Tree, i: number): number[] {
  const m = t.xf.subarray(i * 6, i * 6 + 6);
  const w = t.size[i * 2];
  const h = t.size[i * 2 + 1];
  return [m[4], m[5], m[0] * w + m[4], m[1] * w + m[5], m[0] * w + m[2] * h + m[4], m[1] * w + m[3] * h + m[5], m[2] * h + m[4], m[3] * h + m[5]];
}

/** The node's box on the page, axis-aligned: x0, y0, x1, y1. */
export function aabb(t: Tree, i: number): number[] {
  const c = corners(t, i);
  return [Math.min(c[0], c[2], c[4], c[6]), Math.min(c[1], c[3], c[5], c[7]), Math.max(c[0], c[2], c[4], c[6]), Math.max(c[1], c[3], c[5], c[7])];
}

/** The deepest visible, unlocked layer at page point (x, y) by its real shape (the
 * engine's hit test), as an index of `t`; -1: none. `tol`: page units of slack. */
export function hitDeepest(t: Tree, x: number, y: number, tol = 0): number {
  if (t.page < 0) return -1;
  const id = hitShape(t.page, x, y, tol);
  return id ? (t.index.get(id) ?? -1) : -1;
}

/** Nodes that act like the page for clicks: their children are what a click selects. */
const ARTBOARDS = new Set(["frame", "component", "component-set", "section"]);

/** What a plain click at the deepest hit `deep` selects, as Figma does: the child of
 * the scope the selection is in (the parent of a selected node on the hit's path), or
 * else the child of the top-level frame (a frame on the page, or in a section) under the
 * point, or the top-level node itself. */
export function clickTarget(t: Tree, deep: number, selected: number[]): number {
  if (deep < 0) return -1;
  const path = pathOf(t, deep);
  // The scope: a selected node's parent that lies on the path (the deepest such).
  let best = -1;
  for (const s of selected) {
    const p = t.parent[s];
    const at = p < 0 ? -1 : path.indexOf(p);
    if (p >= 0 && at >= 0 && at > best) best = at;
    // A selected node on the path: a click inside it keeps it (its siblings' level).
    const own = path.indexOf(s);
    if (own >= 0 && own - 1 > best) best = own - 1;
  }
  if (best >= 0) return path[Math.min(best + 1, path.length - 1)];
  // Sections are see-through: what is in them counts as top level.
  let k = 0;
  while (k < path.length - 1 && typeOf(t, path[k]) === "section") k++;
  const top = path[k];
  const kind = typeOf(t, top);
  // A top-level frame: its children are selected directly (the frame itself when the
  // click lands on its own background).
  if (ARTBOARDS.has(kind) && kind !== "section") return k + 1 < path.length ? path[k + 1] : top;
  return top;
}

/** The rows the layers panel lists: nodes whose ancestors are all expanded. */
export function flatten(t: Tree, expanded: Set<string>): Int32Array {
  const out = new Int32Array(t.n);
  let n = 0;
  let i = 0;
  while (i < t.n) {
    out[n++] = i;
    i = expanded.has(t.ids[i]) ? i + 1 : t.end[i];
  }
  return out.subarray(0, n);
}
