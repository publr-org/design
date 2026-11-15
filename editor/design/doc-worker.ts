// The shell's document worker: holds the open file's Pubd JSON (document.json and the
// page shown) off the page's thread and answers what the panels ask: the page's layer
// tree as flat typed arrays (DFS, top-most first, with absolute transforms and subtree
// bounds for hit testing), one node's properties, the styles and the local components.
//
// The render workers keep the engine's own copy; this one is the stand-in for the
// engine's node JSON and hit test (doc.ts), which the panels switch to once it exists.
//
// Messages in (each answered with the same `id`):
//   { type: "open", source }   source: { kind: "file", id } | { kind: "url", base }
//                              | { kind: "fig", url, wasm }
//   { type: "page", page }     the page's tree (and its nodes kept here for "node")
//   { type: "node", node }     a node of the page shown (by id), without its children
//   { type: "components" }     every component and component set in the file
//   { type: "close" }

import { readPath, unpack } from "../home/store";
import { Engine } from "../viewer/engine";
import { F, TYPES } from "./doc-types";

type Scope = {
  postMessage(message: unknown, transfer?: Transferable[]): void;
  onmessage: ((event: MessageEvent) => void) | null;
};

/** A Pubd node as JSON. */
type Node = {
  id: string;
  type: string;
  name?: string;
  visible?: boolean;
  locked?: boolean;
  transform?: number[];
  size?: number[];
  clip?: boolean;
  mask?: string;
  reverseZ?: boolean;
  children?: Node[];
  src?: string;
  background?: unknown;
  frames?: unknown[];
  [key: string]: unknown;
};

type Doc = { name: string; pages: Node[]; styles?: Record<string, Style>; shared?: Node[] };
type Style = { type: string; name: string; description?: string; value?: unknown; library?: boolean; deleted?: boolean };

import type { Source } from "./doc-types";

const scope = self as unknown as Scope;
const decoder = new TextDecoder();

let doc: Doc | null = null;
let read: (path: string) => Promise<Uint8Array | null> = async () => null;
/** The page shown: its index and nodes by id. */
let shown = -1;
let byId = new Map<string, Node>();
let parentOf = new Map<string, Node>();

const parse = (bytes: Uint8Array) => JSON.parse(decoder.decode(bytes)) as unknown;

async function open(source: Source): Promise<Record<string, unknown>> {
  doc = null;
  shown = -1;
  byId = new Map();
  parentOf = new Map();
  samples.clear();
  if (source.kind === "fig") {
    // A .fig: the engine imports it and hands over its Pubd (every page in it).
    const r = await fetch(source.url);
    if (!r.ok) throw new Error(`${source.url}: ${r.status}`);
    const engine = await Engine.create(await WebAssembly.compileStreaming(fetch(source.wasm)));
    engine.loadFig(new Uint8Array(await r.arrayBuffer()));
    doc = parse(engine.pubdJson()) as Doc;
    engine.close();
    read = async () => null;
  } else {
    read = source.kind === "file" ? (path) => readPath(source.id, path) : async (path) => {
      const r = await fetch(source.base + path);
      return r.ok ? unpack(new Uint8Array(await r.arrayBuffer())) : null;
    };
    const bytes = await read("document.json");
    if (!bytes) throw new Error("the file has no document.json");
    doc = parse(bytes) as Doc;
  }
  return {
    name: doc.name,
    pages: doc.pages.map((p) => ({ id: p.id, name: p.name ?? "", background: p.background ?? null })),
    styles: styleList(doc.styles ?? {}),
  };
}

/** A page's nodes: in the document, or read from its own file. */
async function pageNode(index: number): Promise<Node> {
  const d = live();
  const p = d.pages[index];
  if (!p) throw new Error(`no page ${index}`);
  if (p.children || !p.src) return p;
  const bytes = await read(p.src);
  if (!bytes) throw new Error(`the file has no ${p.src}`);
  return parse(bytes) as Node;
}

function live(): Doc {
  if (!doc) throw new Error("no document open");
  return doc;
}

const ID = [1, 0, 0, 1, 0, 0];

function mul(a: number[], b: number[]): number[] {
  return [a[0] * b[0] + a[2] * b[1], a[1] * b[0] + a[3] * b[1], a[0] * b[2] + a[2] * b[3], a[1] * b[2] + a[3] * b[3], a[0] * b[4] + a[2] * b[5] + a[4], a[1] * b[4] + a[3] * b[5] + a[5]];
}

/** The page's tree, depth first and top-most first, as the layers panel lists it. */
function tree(page: Node): { reply: Record<string, unknown>; transfer: Transferable[] } {
  byId = new Map();
  parentOf = new Map();
  const ids: string[] = [];
  const names: string[] = [];
  const types: number[] = [];
  const parent: number[] = [];
  const depth: number[] = [];
  const end: number[] = [];
  const flags: number[] = [];
  const xf: number[] = [];
  const size: number[] = [];
  const sub: number[] = [];
  /** Layout guides, by node: drawn over the canvas by the editor. */
  const grids: [number, unknown[]][] = [];
  const code = new Map(TYPES.map((t, i) => [t, i]));

  const visit = (n: Node, up: number, d: number, m: number[], inherited: number): number => {
    const i = ids.length;
    if (n.styles) sample(n);
    if (Array.isArray(n.grids) && n.grids.length) grids.push([i, n.grids as unknown[]]);
    byId.set(n.id, n);
    ids.push(n.id);
    names.push(n.name ?? "");
    types.push(code.get(n.type) ?? code.get("other")!);
    parent.push(up);
    depth.push(d);
    end.push(0);
    const t = n.transform ?? ID;
    const abs = mul(m, t);
    xf.push(...abs);
    const w = n.size?.[0] ?? 0;
    const h = n.size?.[1] ?? 0;
    size.push(w, h);
    let f = inherited;
    if (n.visible !== false) f |= F.visible;
    if (n.locked) f |= F.locked;
    if (n.mask) f |= F.mask;
    if (n.clip) f |= F.clip;
    if (n.reverseZ) f |= F.reverseZ;
    if (n.type === "rectangle" && Array.isArray(n.fills) && (n.fills as { type?: string }[]).some((p) => p.type === "image")) f |= F.image;
    flags.push(f);
    sub.push(0, 0, 0, 0);
    // The box's corners on the page.
    const xs = [abs[4], abs[0] * w + abs[4], abs[2] * h + abs[4], abs[0] * w + abs[2] * h + abs[4]];
    const ys = [abs[5], abs[1] * w + abs[5], abs[3] * h + abs[5], abs[1] * w + abs[3] * h + abs[5]];
    let b = [Math.min(...xs), Math.min(...ys), Math.max(...xs), Math.max(...ys)];
    const kids = n.children ?? [];
    if (kids.length) {
      let below = inherited;
      if (n.visible === false || inherited & F.hiddenAbove) below |= F.hiddenAbove;
      if (n.locked || inherited & F.lockedAbove) below |= F.lockedAbove;
      if (n.type === "instance") below |= F.inInstance;
      if (n.type === "component" || n.type === "component-set") below |= F.inComponent;
      // Top-most first: the last child is on top, unless the stack is reversed.
      const order = n.reverseZ ? kids : [...kids].reverse();
      const clips = n.clip && n.type !== "group";
      for (const c of order) {
        parentOf.set(c.id, n);
        const k = visit(c, i, d + 1, abs, below & ~(F.visible | F.locked | F.mask | F.clip | F.reverseZ | F.image));
        if (!clips) b = [Math.min(b[0], sub[k * 4]), Math.min(b[1], sub[k * 4 + 1]), Math.max(b[2], sub[k * 4 + 2]), Math.max(b[3], sub[k * 4 + 3])];
      }
    }
    sub[i * 4] = b[0];
    sub[i * 4 + 1] = b[1];
    sub[i * 4 + 2] = b[2];
    sub[i * 4 + 3] = b[3];
    end[i] = ids.length;
    return i;
  };

  const roots = page.children ?? [];
  const order = page.reverseZ ? roots : [...roots].reverse();
  for (const c of order) {
    parentOf.set(c.id, page);
    visit(c, -1, 0, ID, 0);
  }
  const a = {
    types: new Uint8Array(types),
    parent: new Int32Array(parent),
    depth: new Uint16Array(depth),
    end: new Int32Array(end),
    flags: new Uint16Array(flags),
    xf: new Float32Array(xf),
    size: new Float32Array(size),
    sub: new Float32Array(sub),
  };
  return {
    reply: { n: ids.length, ids, names, grids, ...a },
    transfer: [a.types.buffer, a.parent.buffer, a.depth.buffer, a.end.buffer, a.flags.buffer, a.xf.buffer, a.size.buffer, a.sub.buffer],
  };
}

/** Styles whose value the document leaves out, shown as the first node following each
 * draws it (a node stores its styles' resolved values). */
const samples = new Map<string, Node>();

function sample(n: Node): void {
  for (const id of Object.values(n.styles as Record<string, string>)) if (!samples.has(id)) samples.set(id, n);
}

/** What the properties panel reads of a node: its own fields without its children or
 * its resolved geometry, its parent's kind and layout, and its main component's name. */
function nodeInfo(id: string): Record<string, unknown> | null {
  const n = byId.get(id);
  if (!n) return null;
  const { children, glyphs, glyphRects, geometry, network, ...own } = n;
  const strokeOwn = own.stroke as Record<string, unknown> | undefined;
  if (strokeOwn && "outline" in strokeOwn) {
    const { outline, ...rest } = strokeOwn;
    void outline;
    own.stroke = rest;
  }
  void glyphs;
  void glyphRects;
  void geometry;
  void network;
  const p = parentOf.get(id);
  const main = typeof n.component === "string" ? byId.get(n.component) : undefined;
  const styles = live().styles ?? {};
  const styleNames: Record<string, string> = {};
  for (const [k, v] of Object.entries((n.styles as Record<string, string> | undefined) ?? {})) styleNames[k] = styles[v]?.name ?? "";
  return {
    node: own,
    children: children?.length ?? 0,
    parent: p ? { id: p.id, type: p.type, name: p.name ?? "", layout: p.layout ?? null, size: p.size ?? null } : null,
    main: main ? main.name ?? "" : typeof n.component === "string" ? "" : null,
    styleNames,
  };
}

/** Every component and component set, page by page (pages kept in their own files
 * are read one at a time and let go). */
async function components(): Promise<Record<string, unknown>[]> {
  const d = live();
  const out: Record<string, unknown>[] = [];
  for (let i = 0; i < d.pages.length; i++) {
    const p = i === shown ? null : await pageNode(i);
    const walk = (n: Node, set: string) => {
      if (n.type === "component-set") {
        out.push({ id: n.id, name: n.name ?? "", page: i, set: "", kind: "set", variants: (n.children ?? []).length });
        for (const c of n.children ?? []) walk(c, n.name ?? "");
        return;
      }
      if (n.type === "component") {
        out.push({ id: n.id, name: n.name ?? "", page: i, set, kind: "component", variants: 0 });
        return;
      }
      for (const c of n.children ?? []) walk(c, set);
    };
    const root = p ?? shownPage;
    for (const c of root?.children ?? []) walk(c, "");
  }
  return out;
}

let shownPage: Node | null = null;

/** Styles as the panel lists them: name, kind and a short description of the value. */
function styleList(styles: Record<string, Style>): Record<string, unknown>[] {
  return Object.entries(styles).map(([id, s]) => {
    const n = samples.get(id);
    const value = s.value ?? (n ? (s.type === "text" ? n.style : s.type === "fill" ? n.fills : s.type === "effect" ? n.effects : n.grids) : undefined);
    const full = { ...s, value };
    return { id, type: s.type, name: s.name, detail: styleDetail(full), swatch: styleSwatch(full), effect: s.type === "effect" && Array.isArray(full.value) ? String((full.value[0] as { type?: string } | undefined)?.type ?? "") : "", stored: s.value !== undefined, own: !s.library && !s.deleted };
  });
}

function styleDetail(s: Style): string {
  if (s.type !== "text" || !s.value || typeof s.value !== "object") return "";
  const v = s.value as { size?: number; lineHeight?: unknown };
  const lh = v.lineHeight;
  const line = !lh || lh === "auto" ? "Auto" : typeof lh === "object" && lh && "px" in lh ? String((lh as { px: number }).px) : typeof lh === "object" && lh && "percent" in lh ? `${(lh as { percent: number }).percent}%` : "Auto";
  return `${round(v.size ?? 16)}/${line}`;
}

const round = (v: number) => Math.round(v * 100) / 100;

/** A colour style's first paint as CSS, for its swatch. */
function styleSwatch(s: Style): string {
  if (s.type !== "fill" || !Array.isArray(s.value)) return "";
  const p = s.value[0] as { type?: string; color?: unknown; stops?: { color: unknown }[] } | undefined;
  if (!p) return "";
  if (p.type === "solid") return css(p.color);
  if (p.stops?.length) return `linear-gradient(90deg, ${p.stops.map((st) => css(st.color)).join(", ")})`;
  return "";
}

function css(c: unknown): string {
  if (typeof c === "string") return c;
  if (Array.isArray(c)) return `rgba(${Math.round(c[0] * 255)},${Math.round(c[1] * 255)},${Math.round(c[2] * 255)},${c[3] ?? 1})`;
  return "transparent";
}

async function handle(m: Record<string, unknown>): Promise<[Record<string, unknown>, Transferable[]]> {
  switch (m.type) {
    case "open":
      return [await open(m.source as Source), []];
    case "page": {
      const index = m.page as number;
      const page = await pageNode(index);
      shown = index;
      shownPage = page;
      const t = tree(page);
      return [{ ...t.reply, styles: styleList(live().styles ?? {}) }, t.transfer];
    }
    case "node":
      return [{ info: nodeInfo(m.node as string) }, []];
    case "components":
      return [{ list: await components() }, []];
    case "close":
      doc = null;
      shown = -1;
      shownPage = null;
      byId = new Map();
      parentOf = new Map();
      return [{}, []];
    default:
      throw new Error(`unknown message ${String(m.type)}`);
  }
}

scope.onmessage = (event: MessageEvent) => {
  const m = event.data as Record<string, unknown>;
  handle(m).then(
    ([reply, transfer]) => scope.postMessage({ id: m.id, ok: true, ...reply }, transfer),
    (err: unknown) => scope.postMessage({ id: m.id, ok: false, error: err instanceof Error ? err.message : String(err) }),
  );
};
