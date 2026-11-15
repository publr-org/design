// The editor shell's state, as one store every panel reads, and the actions that change
// it: the document's pages and the page's tree (doc.ts), the selection and hover, the
// layers panel's rows (only those in view), the tool, the theme, the rulers and the
// properties the Design tab shows (inspector.ts). The panels render store values only;
// the canvas marks are drawn by overlay.ts from the same store. Edits go through
// edits.ts (viewer/edit.ts underneath); the store follows each one.
//
// For canvas tools, stable:
//   Selection   `shell.selection` (ids, the order picked), `select(ids, scrollTo?)`,
//               `addToSelection(ids)`, `removeFromSelection(ids)`, `clearSelection()`,
//               `selectionScope()` (the parent id the selection's siblings share; "" on
//               the page), `selectionBox()`, `targetAt(x, y, deep)`.
//   Changes     `onDocChange(fn)`: after every edit, step commit or cancel, undo and
//               redo, once the tree, the layers, the Design tab and the marks show it (in
//               the same frame). `fn({ why, ids, structure })`: `ids` the nodes the
//               changes named, `structure` true when layers were added, removed or moved.
//               Returns the unsubscribe.
//   The tree    `currentTree()` (doc.ts Tree, the live page, rebuilt after each change).

import { Publr } from "publr-jsx";
import { route } from "../app/route";
import { getMeta, SERVED_ID, servedEdits } from "../home/store";
import { feedOf } from "../viewer/feed";
import { servedDoc } from "../viewer/loader";
import type { Stage } from "../viewer/stage";
import type { ChangeWhy } from "../viewer/edit";
import type { EditOut } from "../viewer/engine";
import { choosePage, ENGINE_LIMIT, memoryUse, rename, state as viewer, viewerEditing, viewerHooks, viewerStage } from "../viewer/Viewer.ptsx";
import type { MemoryUse } from "../viewer/Viewer.ptsx";
import { aabb, childrenOf, clickTarget, closeDoc, EMPTY, F, flatten, hitDeepest, listComponents, listedFirst, loadTree, nodeNow, openDoc, pathOf, treeNow, typeOf, within } from "./doc";
import type { ComponentInfo, NodeInfo, Source, StyleInfo, Tree } from "./doc";
import { hasFace, moveLayer, renameLayer, setLockedOf, setVisibleOf } from "./edits";
import { inspect } from "./inspector";
import type { Inspector } from "./inspector";
import { Overlay } from "./overlay";

const untracked = <T>(fn: () => T): T => Publr.untrack(fn);

export type ToolName =
  | "move"
  | "hand"
  | "scale"
  | "frame"
  | "section"
  | "slice"
  | "rectangle"
  | "line"
  | "arrow"
  | "ellipse"
  | "polygon"
  | "star"
  | "image"
  | "pen"
  | "pencil"
  | "text"
  | "code-layer"
  | "comment"
  | "actions";

/** A row of the layers panel, as drawn. */
export type LayerRow = {
  id: string;
  /** Its position in the list (its top is `at * 32`). */
  at: number;
  name: string;
  /** Its icon. */
  icon: string;
  depth: number;
  /** Has children: a chevron. */
  parent: boolean;
  expanded: boolean;
  selected: boolean;
  /** Inside a selected node (tinted). */
  tinted: boolean;
  /** The last tinted row under a selection (rounded below). */
  tintEnd: boolean;
  /** Selected and showing its children (tinted below the pill). */
  tintBelow: boolean;
  hovered: boolean;
  /** Instance or component, or inside an instance: purple. */
  purple: boolean;
  hidden: boolean;
  locked: boolean;
  /** The variable modes it sets itself ("Dark mode"), its badge ("" none). */
  badge: string;
  /** Its share of the memory limit, as the layers panel shows it ("" not shown). */
  memory: string;
};

export type PageRow = { key: string; index: number; name: string; current: boolean; renaming: boolean; divider: boolean };
export type StyleGroup = { key: string; title: string; rows: { key: string; name: string; detail: string; swatch: string; effect: string; kind: string; folder: boolean; depth: number; open: boolean }[] };
export type AssetRow = { id: string; name: string; page: number; pageName: string; set: string; kind: string };

/** The height of a layer row. */
export const ROW = 32;

export const shell = Publr.reactive({
  /** The file is open and its tree read. */
  ready: false,
  dark: true,
  /** "system" follows the browser; else the main menu's choice. */
  themePref: "system" as "system" | "light" | "dark",
  leftTab: "file" as "file" | "assets",
  leftOpen: true,
  rightTab: "design" as "design" | "prototype",
  tool: "move" as ToolName,
  /** The last tool chosen in each toolbar group (the group's button shows it). */
  moveTool: "move" as ToolName,
  frameTool: "frame" as ToolName,
  shapeTool: "rectangle" as ToolName,
  penTool: "pen" as ToolName,
  mode: "design" as "draw" | "design" | "motion" | "dev",
  rulers: false,
  /** Layout guides shown (Shift+G). */
  guides: true,
  zoomLabel: "100%",
  fileName: "",
  location: "",
  renamingFile: false,
  pages: [] as PageRow[],
  /** The selected nodes' ids. */
  selection: [] as string[],
  hover: "",
  /** Revision bumped whenever the canvas marks change (overlay.ts redraws). */
  marks: 0,
  /** The layers panel: the rows in view and the list's whole height. */
  rows: [] as LayerRow[],
  listHeight: 0,
  /** The list's least width (deep rows need more than the panel: it scrolls sideways). */
  listWidth: 0,
  inspector: null as Inspector | null,
  styles: [] as StyleGroup[],
  pageBackground: "",
  pageBackgroundHex: "",
  assets: [] as AssetRow[],
  assetsQuery: "",
  assetsLoading: false,
  /** The layer whose name is being typed in the layers panel ("" none). */
  renamingLayer: "",
  /** Edits to this file are not saved (the document `pe view` serves). */
  notSaved: false,
  /** The layers panel's drop mark while a row is dragged: its top (px), indent (px), and
   * the row framed when the drop goes inside it. */
  dropLine: -1,
  dropIndent: 0,
  dropInto: "",
  /** Constrain proportions (W and H scale together). */
  constrain: false,
  /** Padding and corner radius shown side by side / corner by corner. */
  padSides: false,
  radiusCorners: false,
  strokeSides: false,
  /** The effect whose settings show under it (-1 none). */
  effectOpen: -1,
  /** The panels and the toolbar hidden: the canvas alone (Cmd+backslash, Show/Hide UI). */
  uiHidden: false,
  /** View > Memory usage: the panel under the file's name, and its numbers. */
  memory: false,
  /** Go to main component left an instance behind: the bar to return to it shows while
   * the main's page does (null: no bar). */
  returnTo: null as { instance: string; page: number; mainPage: number } | null,
  memoryUse: { share: 0, active: 0, images: 0, gpu: 0, workers: 0, warm: 0, reserved: 0, total: 0, budget: 1, page: 0, pageBytes: [] } as MemoryUse,
  /** The Manage memory window, and the layers on the page it counts. */
  memoryWindow: false,
  pageLayers: 0,
  /** Each page's and layer's share shown in the pages and layers lists (Manage
   * memory's switch). */
  memoryLayers: false,
  /** Each page's share as the pages list shows it, by page index ("–" never read). */
  pageMemory: [] as string[],
});

/** The page's tree (EMPTY while none). */
let tree: Tree = EMPTY;
/** The rows the layers list has (node indices), all of them; only a window is drawn. */
let flat = new Int32Array(0);
const expanded = new Set<string>();
let viewTop = 0;
let viewHeight = 600;
/** Which engine page the tree is for (-1: none). */
let treePage = -1;
let opened = "";
let styles: StyleInfo[] = [];
let components: ComponentInfo[] = [];
let pageNames: string[] = [];
/** The page being renamed (its id). */
let renamingPage = "";
let currentPage = 0;
let styleOpen = new Set<string>();
/** What the Design tab shows, as read (edits.ts builds changes from these). */
let infos: NodeInfo[] = [];
/** Nodes to select once their page's tree is in (an asset on another page, an undo). */
let pendingSelect: string[] = [];
/** The selection a page switch waits for fills the view once it is there. */
let pendingZoom = false;
/** The selection of each file left for another tab, put back when it shows again. */
const keptSelection = new Map<string, string[]>();

export const currentTree = () => tree;

// ------------------------------------------------------------ theme

const media = typeof matchMedia === "function" ? matchMedia("(prefers-color-scheme: dark)") : null;

function readPref(): "system" | "light" | "dark" {
  try {
    const v = localStorage.getItem("pd-theme");
    return v === "light" || v === "dark" ? v : "system";
  } catch {
    return "system";
  }
}

export function applyTheme(): void {
  const dark = shell.themePref === "system" ? (media?.matches ?? true) : shell.themePref === "dark";
  shell.dark = dark;
  const html = document.documentElement;
  const on = route.screen === "file" || route.screen === "content";
  html.classList.toggle("pd", on);
  html.classList.toggle("pd-dark", on && dark);
  // The page's own first paint (its head's boot script) is over: the shell paints now.
  html.classList.remove("pd-boot");
}

export function setTheme(pref: "system" | "light" | "dark"): void {
  shell.themePref = pref;
  try {
    if (pref === "system") localStorage.removeItem("pd-theme");
    else localStorage.setItem("pd-theme", pref);
  } catch {
    // The choice holds for this visit only.
  }
  applyTheme();
}

shell.themePref = readPref();
media?.addEventListener("change", () => applyTheme());

// ------------------------------------------------------------ memory usage

/** View > Memory usage on or off; remembered, as Figma remembers it. */
export function toggleMemory(): void {
  shell.memory = !shell.memory;
  try {
    if (shell.memory) localStorage.setItem("pd-memory", "1");
    else localStorage.removeItem("pd-memory");
  } catch {
    // The choice holds for this visit only.
  }
  readMemory();
}

/** Manage memory: its window opens beside the panels, or closes. */
export function toggleMemoryWindow(): void {
  shell.memoryWindow = !shell.memoryWindow;
  readMemory();
}

/** Manage memory's switch: each layer's share in the layers panel; remembered. */
export function toggleMemoryLayers(): void {
  shell.memoryLayers = !shell.memoryLayers;
  try {
    if (shell.memoryLayers) localStorage.setItem("pd-memory-layers", "1");
    else localStorage.removeItem("pd-memory-layers");
  } catch {
    // The choice holds for this visit only.
  }
  readMemory();
  drawRows();
}

/** The numbers, read again each second while the panel, the window or the layers'
 * shares show (one reading at a time: the workers are asked). */
let reading = false;
function readMemory(): void {
  if (reading || !(shell.memory || shell.memoryWindow || shell.memoryLayers) || route.screen !== "file") return;
  reading = true;
  shell.pageLayers = tree.n;
  void memoryUse()
    .then((use) => {
      readPageMemory(use);
      const was = shell.memoryUse;
      if ((Object.keys(use) as (keyof MemoryUse)[]).every((k) => k === "pageBytes" || use[k] === was[k])) return;
      shell.memoryUse = use;
      if (shell.memoryLayers) drawRows();
    })
    .catch((err) => console.error("memory", err))
    .finally(() => (reading = false));
}

/** What each page took when last in memory, by file and page id: a page let go keeps
 * its last measure (it costs nothing now, and that much when shown again). */
const pageMeasures = new Map<string, number>();

function readPageMemory(use: MemoryUse): void {
  if (!shell.memoryLayers) return;
  const pages = livePages();
  for (const { page, bytes } of use.pageBytes) if (pages[page]) pageMeasures.set(`${viewer.fileId}/${pages[page].id}`, bytes);
  const next = pages.map((p) => {
    const bytes = pageMeasures.get(`${viewer.fileId}/${p.id}`);
    return bytes === undefined ? "–" : percentOf(bytes / ENGINE_LIMIT);
  });
  if (next.length !== shell.pageMemory.length || next.some((v, i) => v !== shell.pageMemory[i])) shell.pageMemory = next;
}

/** Layer `i`'s share of an engine's limit: the page's bytes shared out by layer count (a layer
 * holds about as much as the layers in it), as a percentage. */
function layerMemory(i: number): string {
  const use = shell.memoryUse;
  // A file read whole (not page by page): its nodes are what it has in use, less its
  // images, the GPU and the workers.
  const page = use.page || Math.max(0, use.active - use.images - use.gpu - use.workers);
  if (!tree.n || !page) return "";
  return percentOf((((tree.end[i] - i) / tree.n) * page) / ENGINE_LIMIT);
}

/** A share of the limit as the memory panels write it: 48.7%, <0.1% for a trace. */
export function percentOf(share: number): string {
  const p = share * 100;
  return p > 0 && p < 0.1 ? "<0.1%" : `${p.toFixed(1)}%`;
}

try {
  shell.memory = localStorage.getItem("pd-memory") === "1";
  shell.memoryLayers = localStorage.getItem("pd-memory-layers") === "1";
} catch {
  // Off.
}
setInterval(readMemory, 1000);

// ------------------------------------------------------------ opening

/** Where the shell reads file `id` from. */
async function sourceOf(id: string, wasm: string): Promise<Source | null> {
  if (id !== SERVED_ID) return { kind: "file", id };
  const info = await servedDoc();
  if (!info) return null;
  // Its edits, kept in a file of the browser, are what the canvas shows.
  const edits = info.kind === "pubd" ? await servedEdits(info.name) : null;
  if (edits) return { kind: "file", id: edits.id };
  return info.kind === "fig" ? { kind: "fig", url: info.url, wasm } : { kind: "url", base: "/doc/" };
}

let wasmUrl = "";

/** Where the engine's WASM build is (the worker imports .fig files with it). */
export function configureShell(wasm: string): void {
  wasmUrl = wasm;
}

/** Opens file `id` in the shell's panels (the viewer opens it on the canvas itself). */
export async function openShell(id: string, location: string, name: string): Promise<void> {
  if (opened === id) return;
  // The file left keeps its selection while it stays open in another tab.
  if (opened) keptSelection.set(opened, [...shell.selection]);
  opened = id;
  shell.ready = false;
  shell.fileName = name;
  shell.location = location;
  clearSelection();
  tree = EMPTY;
  treePage = -1;
  flat = new Int32Array(0);
  expanded.clear();
  components = [];
  shell.assets = [];
  refreshRows();
  const source = await sourceOf(id, wasmUrl);
  if (!source || opened !== id) return;
  try {
    const info = await openDoc(source);
    if (!info || opened !== id) return;
    pageNames = info.pages.map((p, i) => p.name || `Page ${i + 1}`);
    styles = info.styles;
    // A .fig import made before files kept their styles' values: colour swatches and
    // "20/Auto" show only where a layer uses the style. Importing again fills them in.
    if (id !== SERVED_ID && styles.some((s) => s.type !== "grid" && !s.stored) && (await getMeta(id))?.source === "fig") viewer.reimport = true;
    buildPages();
    buildStyles();
    shell.ready = true;
    pendingSelect = keptSelection.get(id) ?? [];
    keptSelection.delete(id);
    await showTree(Number(viewer.page) || 0);
  } catch (err) {
    console.error("shell: open", err);
  }
}

export function closeShell(): void {
  opened = "";
  shell.returnTo = null;
  closeDoc();
  tree = EMPTY;
  treePage = -1;
  flat = new Int32Array(0);
  shell.ready = false;
  shell.pages = [];
  shell.styles = [];
  shell.inspector = null;
  clearSelection();
  refreshRows();
}

/** The viewer shows engine page `index`: the panels follow. */
export async function showTree(index: number): Promise<void> {
  currentPage = index;
  buildPages();
  if (!shell.ready || treePage === index) return;
  treePage = index;
  clearSelection();
  expanded.clear();
  tree = EMPTY;
  refreshRows();
  const t0 = performance.now();
  const t = await loadTree(index).catch((err) => {
    console.error("shell: page", err);
    return null;
  });
  if (!t || treePage !== index) return;
  tree = t;
  if (t.styles.length) {
    styles = t.styles;
    buildStyles();
  }
  console.info(`layers: ${t.n} nodes in ${Math.round(performance.now() - t0)} ms`);
  refreshRows();
  refreshInspector();
  const wanted = pendingSelect.filter((id) => t.index.has(id));
  pendingSelect = [];
  const zoom = pendingZoom;
  pendingZoom = false;
  if (wanted.length) select(wanted);
  if (wanted.length && zoom) zoomSelection();
}

// ------------------------------------------------------------ pages

/** The pages as the engine has them now (names, order, backgrounds). */
function livePages(): { id: string; name: string; background: number[] | null }[] {
  return stage()?.doc?.pages ?? [];
}

function buildPages(): void {
  // A page named only with dashes ("---") is a divider in the list, as in the editor.
  const pages = livePages();
  pageNames = pages.map((p, i) => p.name || `Page ${i + 1}`);
  // Keys are the page ids; a file an earlier build imported may repeat one (a page's id
  // and name split wrongly), and the list needs its keys unique: a repeat keys by place.
  const seen = new Set<string>();
  const keyOf = (id: string, index: number) => (seen.has(id) ? `${id}#${index}` : (seen.add(id), id));
  shell.pages = pages.map((p, index) => {
    const key = keyOf(p.id, index);
    return { key, index, name: pageNames[index], current: index === currentPage, renaming: renamingPage === key, divider: /^[-–—\s]+$/.test(p.name) };
  });
  const bg = background(currentPage);
  shell.pageBackground = bg.css;
  shell.pageBackgroundHex = bg.hex;
  // The page shown stays in view in the list (a link may open one far down it).
  if (shownInList !== currentPage) {
    shownInList = currentPage;
    requestAnimationFrame(() => document.querySelector("[data-pd-pages] [data-pd-page-current]")?.scrollIntoView({ block: "nearest" }));
  }
}

/** The page the list last scrolled to. */
let shownInList = -1;

/** The page backgrounds changed (the viewer read the pages again). */
export function setPageBackgrounds(_list: unknown[]): void {
  buildPages();
}

function background(index: number): { css: string; hex: string } {
  const c = livePages()[index]?.background;
  if (!c) return { css: "#f5f5f5", hex: "F5F5F5" };
  const h = (v: number) => Math.round(Math.max(0, Math.min(1, v)) * 255).toString(16).padStart(2, "0");
  const hex = `${h(c[0])}${h(c[1])}${h(c[2])}`.toUpperCase();
  return { css: `#${hex}`, hex };
}

/** The page shown: its index and its node's id. */
export const currentPageIndex = () => currentPage;
export const currentPageId = () => livePages()[currentPage]?.id ?? "";

/** The file's components (Assets reads them; instance swap lists them). */
export const componentList = () => components;

/** Applies changes to the document (one step), as edits.ts does; false when nothing is
 * open or the engine refused them. */
export function editDoc(changes: unknown): boolean {
  const ed = viewerEditing();
  if (!ed?.engine) return false;
  try {
    ed.edit(changes);
    return true;
  } catch (err) {
    console.error("edit", err);
    return false;
  }
}

/** Adds a page after the last one and names it ("Page 3"), ready to rename. */
export function addPage(): void {
  const n = livePages().length + 1;
  if (!editDoc({ op: "insert", parent: "", index: n - 1, node: { id: "", type: "page", name: `Page ${n}`, background: "#f5f5f5" } })) return;
  const pages = livePages();
  const added = pages[pages.length - 1];
  if (added) {
    renamingPage = added.id;
    showPage(pages.length - 1);
  }
  buildPages();
}

/** The place of the page listed under `key` (-1 when gone). */
function pageIndex(key: string): number {
  return shell.pages.find((p) => p.key === key)?.index ?? -1;
}

/** The id that edits page `index` by: none when another page has it too (a file an
 * earlier build imported), as an edit by id cannot tell them apart. */
function pageEditId(index: number): string | null {
  const pages = livePages();
  const id = pages[index]?.id;
  if (!id) return null;
  if (pages.some((p, i) => i !== index && p.id === id)) {
    console.warn(`page "${pages[index].name}": its id ${id} repeats; import the file again to edit its pages`);
    return null;
  }
  return id;
}

export function startRenamePage(key: string): void {
  renamingPage = key;
  buildPages();
}

export function renamePage(key: string, name: string): void {
  renamingPage = "";
  const at = pageIndex(key);
  const p = livePages()[at];
  if (p && name.trim() && name.trim() !== p.name) {
    const id = pageEditId(at);
    if (id) editDoc({ op: "set", node: id, props: { name: name.trim() } });
  }
  buildPages();
}

/** Moves the page `key` to before `before` ("" : to the end). */
export function movePage(key: string, before: string): void {
  if (!key || key === before) return;
  const pages = livePages();
  const from = pageIndex(key);
  const id = pageEditId(from);
  if (!id) return;
  let to = before ? pageIndex(before) : pages.length;
  if (to < 0) to = pages.length;
  if (to > from) to--;
  if (to === from) return;
  const shown = pages[currentPage]?.id;
  editDoc({ op: "move", node: id, parent: "", index: to });
  followPage(shown);
}

/** Deletes page `key` (never the last one). */
export function deletePage(key: string): void {
  const pages = livePages();
  if (pages.length <= 1) return;
  const at = pageIndex(key);
  const id = pageEditId(at);
  if (!id) return;
  const shown = at === currentPage ? pages[at === 0 ? 1 : at - 1]?.id : pages[currentPage]?.id;
  editDoc({ op: "delete", node: id });
  followPage(shown);
}

/** Duplicates page `key` (its layers copied) after it. */
export function duplicatePage(key: string): void {
  const e = viewerEditing()?.engine;
  const at = pageIndex(key);
  const id = pageEditId(at);
  if (!e || !id) return;
  try {
    const copy = e.nodeJson(id);
    copy.name = `${String(copy.name ?? "")} copy`;
    editDoc({ op: "insert", parent: "", index: at + 1, node: copy });
  } catch (err) {
    console.error("duplicate page", err);
  }
  buildPages();
}

/** After pages moved, shows page `id` at its new place. */
function followPage(id: string | undefined): void {
  const at = id ? livePages().findIndex((p) => p.id === id) : -1;
  treePage = -1;
  if (at >= 0) showPage(at);
  buildPages();
}

// ------------------------------------------------------------ the layers list

/** The layers list's scroll position and height changed. */
export function layersViewport(top: number, height: number): void {
  viewTop = top;
  viewHeight = height;
  drawRows();
}

/** Rebuilds the list's rows (after expanding, collapsing or a new tree). */
function refreshRows(): void {
  flat = flatten(tree, expanded);
  shell.listHeight = flat.length * ROW + 8;
  drawRows();
}

const ICONS: Record<string, string> = {
  frame: "l-frame",
  group: "l-group",
  section: "l-section",
  component: "l-component",
  "component-set": "l-component-set",
  instance: "l-instance",
  text: "l-text",
  rectangle: "l-rectangle",
  ellipse: "l-ellipse",
  line: "l-line",
  vector: "l-vector",
  star: "l-star",
  polygon: "l-polygon",
  boolean: "l-boolean",
  slice: "l-slice",
};

/** The icon of node `i`: by kind, with frames by their auto layout. */
export function iconOf(t: Tree, i: number, layout?: string): string {
  const type = typeOf(t, i);
  const f = t.flags[i];
  layout ??= f & F.autoH ? "horizontal" : f & F.autoV ? "vertical" : f & F.autoGrid ? "grid" : undefined;
  if (t.flags[i] & F.mask) return "l-mask";
  if (t.flags[i] & F.image) return "l-image";
  if (type === "frame" && layout) return layout === "horizontal" ? "l-row" : layout === "vertical" ? "l-column" : "l-grid";
  return ICONS[type] ?? "l-rectangle";
}

/** Indices of the selected nodes in the tree. */
function selectedIndices(): number[] {
  const out: number[] = [];
  for (const id of shell.selection) {
    const i = tree.index.get(id);
    if (i !== undefined) out.push(i);
  }
  return out;
}

/** Draws the rows in view (and a few around them). */
function drawRows(): void {
  const first = Math.max(0, Math.floor(viewTop / ROW) - 6);
  const last = Math.min(flat.length, Math.ceil((viewTop + viewHeight) / ROW) + 6);
  const sel = selectedIndices();
  const selSet = new Set(sel);
  const rows: LayerRow[] = [];
  for (let at = first; at < last; at++) {
    const i = flat[at];
    const id = tree.ids[i];
    const f = tree.flags[i];
    const type = typeOf(tree, i);
    const hasKids = tree.end[i] > i + 1;
    const open = hasKids && expanded.has(id);
    const selected = selSet.has(i);
    let tinted = false;
    for (const s of sel) if (s !== i && within(tree, i, s)) tinted = true;
    const next = at + 1 < flat.length ? flat[at + 1] : -1;
    let nextTinted = false;
    if (next >= 0) for (const s of sel) if (s !== next && within(tree, next, s)) nextTinted = true;
    const row: LayerRow = {
      id,
      at,
      name: tree.names[i] || type,
      icon: iconOf(tree, i),
      depth: tree.depth[i],
      parent: hasKids,
      expanded: open,
      selected,
      tinted: tinted && !selected,
      tintEnd: (tinted || (selected && open)) && !nextTinted,
      tintBelow: selected && open && nextTinted,
      hovered: shell.hover === id,
      purple: type === "instance" || type === "component" || type === "component-set" || (f & (F.inInstance | F.inComponent)) !== 0,
      hidden: !(f & F.visible) || (f & F.hiddenAbove) !== 0,
      locked: (f & F.locked) !== 0,
      badge: tree.modes.get(i) ?? "",
      memory: shell.memoryLayers ? layerMemory(i) : "",
    };
    // A row that has not changed keeps its object: the list skips it at once.
    const was = rowCache.get(id);
    const same = was && (Object.keys(row) as (keyof LayerRow)[]).every((k) => was[k] === row[k]);
    rows.push(same ? was! : row);
    if (!same) rowCache.set(id, row);
  }
  if (rowCache.size > 4096) rowCache.clear();
  shell.rows = rows;
  // Deep rows keep their names readable: the list grows wider and scrolls sideways (as
  // Figma's does) rather than squeezing the name away.
  let deepest = 0;
  for (const r of rows) deepest = Math.max(deepest, r.depth);
  shell.listWidth = deepest * 24 + ROW_FIXED + NAME_MIN;
}

/** A row's width besides its indent and name: margins, chevron, icon, the gap, and the
 * column after the name (memory share, or lock and eye on hover). */
const ROW_FIXED = 16 + 4 + 16 + 16 + 8 + 56;
/** The narrowest a layer's name gets before the list scrolls sideways. */
const NAME_MIN = 64;

const rowCache = new Map<string, LayerRow>();

/** The chevron: opens or closes a row; with Alt, the whole subtree. */
export function toggleExpand(id: string, event?: MouseEvent): void {
  event?.stopPropagation();
  const open = !expanded.has(id);
  const i = tree.index.get(id);
  if (event?.altKey && i !== undefined) {
    for (let j = i; j < tree.end[i]; j++) {
      if (tree.end[j] <= j + 1) continue;
      if (open) expanded.add(tree.ids[j]);
      else expanded.delete(tree.ids[j]);
    }
  } else if (open) expanded.add(id);
  else expanded.delete(id);
  refreshRows();
}

/** Expands every ancestor of the selection and scrolls the first selected row into view. */
function reveal(): void {
  const sel = selectedIndices();
  if (!sel.length) return;
  for (const i of sel) for (let p = tree.parent[i]; p >= 0; p = tree.parent[p]) expanded.add(tree.ids[p]);
  refreshRows();
  const at = flat.indexOf(sel[0]);
  if (at < 0) return;
  const top = at * ROW;
  if (listEl && (top < viewTop || top + ROW > viewTop + viewHeight)) listEl.scrollTop = Math.max(0, top - viewHeight / 3);
  // A deep layer's name in view: the list scrolls sideways to it (and back for a shallow one).
  // (A frame later: the list takes its new width first.)
  const el = listEl;
  if (el) {
    const indent = tree.depth[sel[0]] * 24;
    requestAnimationFrame(() => (el.scrollLeft = Math.max(0, indent - (el.clientWidth - ROW_FIXED - NAME_MIN))));
  }
}

let listEl: HTMLElement | null = null;

/** The layers list's scroller: its position and height decide the rows drawn. */
export const layersList = Publr.ref((el: HTMLElement) => {
  listEl = el;
  const update = () => layersViewport(el.scrollTop, el.clientHeight);
  el.addEventListener("scroll", update, { passive: true });
  const ro = new ResizeObserver(update);
  ro.observe(el);
  update();
  return () => {
    el.removeEventListener("scroll", update);
    ro.disconnect();
    if (listEl === el) listEl = null;
  };
});

// ------------------------------------------------------------ editing in the layers panel

/** Double-click on a layer's name: it is typed in place. */
export function startRenameLayer(id: string): void {
  shell.renamingLayer = id;
}

/** The typed name (Enter or leaving the field); `null` (Escape) keeps the old one. */
export function finishRenameLayer(id: string, name: string | null): void {
  if (shell.renamingLayer !== id) return;
  shell.renamingLayer = "";
  const i = tree.index.get(id);
  if (name !== null && i !== undefined && name.trim() && name !== tree.names[i]) renameLayer(id, name.trim());
}

/** The eye and the lock on a row. */
export function toggleRowVisible(id: string, event: MouseEvent): void {
  event.stopPropagation();
  const i = tree.index.get(id);
  if (i !== undefined) setVisibleOf(id, !(tree.flags[i] & F.visible));
}

export function toggleRowLocked(id: string, event: MouseEvent): void {
  event.stopPropagation();
  const i = tree.index.get(id);
  if (i === undefined) return;
  const lock = !(tree.flags[i] & F.locked);
  setLockedOf(id, lock);
  if (lock && shell.selection.includes(id)) select(shell.selection.filter((x) => x !== id), false);
}

/** The rows dragged, and where they would land. */
let dragIds: string[] = [];
let dropAt: { parent: string; index: number } | null = null;
const CAN_HOLD = new Set(["frame", "group", "component", "component-set", "section", "boolean"]);

/** A press on a row: past a few pixels of movement it becomes a drag of the selected
 * rows (or this one); the panel shows where they would land, release moves them. */
export function layerPointerDown(id: string, event: PointerEvent): void {
  if (event.button !== 0 || shell.renamingLayer) return;
  const i = tree.index.get(id);
  if (i === undefined) return;
  const y0 = event.clientY;
  let dragging = false;
  const move = (e: PointerEvent) => {
    if (!dragging) {
      if (Math.abs(e.clientY - y0) < 4) return;
      if (tree.flags[i] & F.inInstance) return;
      dragging = true;
      dragIds = shell.selection.includes(id)
        ? shell.selection.filter((x) => {
            const k = tree.index.get(x);
            return k !== undefined && !(tree.flags[k] & F.inInstance);
          })
        : [id];
      document.body.style.cursor = "grabbing";
    }
    dropOver(e.clientY);
  };
  const up = () => {
    window.removeEventListener("pointermove", move, true);
    window.removeEventListener("pointerup", up, true);
    document.body.style.cursor = "";
    if (!dragging) return;
    suppressClick = true;
    setTimeout(() => (suppressClick = false), 0);
    layerDrop();
  };
  window.addEventListener("pointermove", move, true);
  window.addEventListener("pointerup", up, true);
}

/** A click that ended a drag selects nothing. */
let suppressClick = false;

/** Where the dragged rows would land with the pointer at `clientY`: above a row,
 * below it, or into it (its middle, for layers that hold others). */
function dropOver(clientY: number): void {
  if (!listEl) return;
  const r = listEl.getBoundingClientRect();
  // The list has 4 px above its first row; each row's pill starts 4 px into it.
  const y = clientY - r.top + listEl.scrollTop - 8;
  const at = Math.max(0, Math.min(flat.length - 1, Math.floor(y / ROW)));
  const i = flat[at];
  if (i === undefined) return clearDrop();
  const id = tree.ids[i];
  for (const d of dragIds) {
    const k = tree.index.get(d);
    if (k !== undefined && i >= k && i < tree.end[k]) return clearDrop();
  }
  if (tree.flags[i] & F.inInstance) return clearDrop();
  const f = Math.max(0, Math.min(1, (y - at * ROW) / ROW));
  const holds = CAN_HOLD.has(typeOf(tree, i));
  const p = tree.parent[i];
  const parentId = p >= 0 ? tree.ids[p] : "";
  const sibs = childrenOf(tree, p);
  // The panel lists the last child at the top, or (auto layout) the first.
  const listed = listedFirst(tree, p);
  const engineIndex = listed ? sibs.indexOf(i) : sibs.length - 1 - sibs.indexOf(i);
  const above = listed ? engineIndex : engineIndex + 1;
  const below = listed ? engineIndex + 1 : engineIndex;
  const open = expanded.has(id) && tree.end[i] > i + 1;
  if (holds && f > 0.3 && f < 0.7) {
    dropAt = { parent: id, index: 1e9 };
    shell.dropInto = id;
    shell.dropLine = -1;
  } else if (f <= 0.5) {
    dropAt = { parent: parentId, index: above };
    shell.dropInto = "";
    shell.dropLine = at * ROW + 2;
    shell.dropIndent = tree.depth[i] * 24 + 32;
  } else if (open && holds) {
    dropAt = { parent: id, index: 1e9 };
    shell.dropInto = "";
    shell.dropLine = (at + 1) * ROW + 2;
    shell.dropIndent = (tree.depth[i] + 1) * 24 + 32;
  } else {
    dropAt = { parent: parentId, index: below };
    shell.dropInto = "";
    shell.dropLine = (at + 1) * ROW + 2;
    shell.dropIndent = tree.depth[i] * 24 + 32;
  }
}

function clearDrop(): void {
  dropAt = null;
  shell.dropLine = -1;
  shell.dropInto = "";
}

function layerDrop(): void {
  const to = dropAt;
  const ids = dragIds;
  dragIds = [];
  clearDrop();
  if (!to || !ids.length) return;
  const ed = viewerEditing();
  if (!ed?.engine) return;
  // One step for all the rows moved, the top-most first: each lands under the last.
  const ordered = ids.map((id) => tree.index.get(id)!).sort((a, b) => (to.index >= 1e9 ? b - a : a - b)).map((k) => tree.ids[k]);
  ed.begin();
  try {
    for (const id of ordered) moveLayer(id, to.parent, to.index);
  } finally {
    ed.commit();
  }
  if (to.parent) {
    expanded.add(to.parent);
    refreshRows();
  }
}

// ------------------------------------------------------------ selection and hover

/** Selects nothing. */
export function clearSelection(): void {
  shell.selection = [];
  shell.hover = "";
  shell.inspector = null;
  shell.marks++;
  // The rows lose their highlight with it.
  drawRows();
  followSelection();
}

/** Adds `ids` to the selection. */
export function addToSelection(ids: string[]): void {
  select([...shell.selection, ...ids.filter((id) => !shell.selection.includes(id))]);
}

/** Takes `ids` out of the selection. */
export function removeFromSelection(ids: string[]): void {
  select(shell.selection.filter((id) => !ids.includes(id)));
}

/** The parent the selection's layers share ("" : the page, or nothing selected). */
export function selectionScope(): string {
  const sel = selectedIndices();
  if (!sel.length) return "";
  const p = tree.parent[sel[0]];
  return p >= 0 ? tree.ids[p] : "";
}

/** Selects `ids` (empty: nothing). */
export function select(ids: string[], scrollTo = true): void {
  shell.selection = ids;
  shell.marks++;
  followSelection();
  if (scrollTo) reveal();
  else drawRows();
  refreshInspector();
}

/** A click on a layer row: selects it, Shift adds or takes it away. */
export function clickRow(id: string, event: MouseEvent): void {
  if (suppressClick) return;
  if (event.shiftKey || event.metaKey || event.ctrlKey) {
    const has = shell.selection.includes(id);
    select(has ? shell.selection.filter((x) => x !== id) : [...shell.selection, id], false);
  } else {
    select([id], false);
  }
}

export function setHover(id: string): void {
  if (shell.hover === id) return;
  shell.hover = id;
  shell.marks++;
  drawRows();
}

/** Page point (x, y): what a click there selects (`deep`: the deepest node). */
export function targetAt(x: number, y: number, deep: boolean): string {
  // A few screen pixels of slack for thin shapes, as the editor's.
  const d = hitDeepest(tree, x, y, 3 / (stage()?.cam.z ?? 1));
  if (d < 0) return "";
  if (deep) return tree.ids[d];
  const t = clickTarget(tree, d, selectedIndices());
  return t >= 0 ? tree.ids[t] : "";
}

/** A press on the canvas at page point (x, y). */
export function pressCanvas(x: number, y: number, shift: boolean, deep: boolean): void {
  const id = targetAt(x, y, deep);
  if (!id) {
    if (!shift) select([]);
    return;
  }
  if (shift) {
    const has = shell.selection.includes(id);
    select(has ? shell.selection.filter((x) => x !== id) : [...shell.selection, id]);
  } else if (!shell.selection.includes(id)) {
    select([id]);
  }
}

/** A double-click at page point (x, y): one level into the selection. */
export function diveAt(x: number, y: number): void {
  const d = hitDeepest(tree, x, y, 3 / (stage()?.cam.z ?? 1));
  if (d < 0) return;
  const sel = selectedIndices();
  const path = pathOf(tree, d);
  for (const s of sel) {
    const at = path.indexOf(s);
    if (at >= 0 && at + 1 < path.length) {
      select([tree.ids[path[at + 1]]]);
      return;
    }
  }
  const t = clickTarget(tree, d, sel);
  if (t >= 0) select([tree.ids[t]]);
}

/** Enter: the selected nodes' children. */
export function selectChildren(): void {
  const out: string[] = [];
  for (const i of selectedIndices()) for (const c of childrenOf(tree, i)) out.push(tree.ids[c]);
  if (out.length) select(out);
}

/** Shift+Enter or Esc: the parents (none when the selection is top level). */
export function selectParent(): void {
  const out = new Set<string>();
  for (const i of selectedIndices()) {
    const p = tree.parent[i];
    if (p >= 0) out.add(tree.ids[p]);
  }
  select([...out]);
}

/** The selection's box on the page (x0, y0, x1, y1), or null. */
export function selectionBox(): number[] | null {
  const sel = selectedIndices();
  if (!sel.length) return null;
  let b = [Infinity, Infinity, -Infinity, -Infinity];
  for (const i of sel) {
    const a = aabb(tree, i);
    b = [Math.min(b[0], a[0]), Math.min(b[1], a[1]), Math.max(b[2], a[2]), Math.max(b[3], a[3])];
  }
  return b;
}

/** Selected node indices (for the overlay). */
export const selectedNodes = selectedIndices;

/** Whether `id` lies inside a main component (or a set): Figma marks it purple. */
export function inComponent(id: string): boolean {
  const i = tree.index.get(id);
  return i !== undefined && (tree.flags[i] & F.inComponent) !== 0;
}

/** The hovered node's index, or -1. */
export function hoveredNode(): number {
  return shell.hover ? (tree.index.get(shell.hover) ?? -1) : -1;
}

// ------------------------------------------------------------ the inspector

/** What the variables add to the shell (variables.ts sets them): `changed` hears every
 * edit, undo or redo of a variable or collection before the panels read the document
 * again; `inspected` completes the Design tab's model (the variables fields are bound to,
 * the modes a layer sets). */
export const varHooks = {
  changed: null as null | (() => void),
  inspected: null as null | ((infos: NodeInfo[], inspector: Inspector) => void),
};

/** The Design tab reads the selected nodes again (at once: the engine is on this
 * thread). */
function refreshInspector(): void {
  const ids = shell.selection;
  if (!ids.length) {
    infos = [];
    shell.inspector = null;
    return;
  }
  infos = ids.slice(0, 50).map((id) => nodeNow(id)).filter((x): x is NodeInfo => !!x);
  const insp = infos.length ? inspect(infos, ids.length, selectionBox(), hasFace, canvasRotation) : null;
  if (insp) varHooks.inspected?.(infos, insp);
  shell.inspector = insp;
  // Instance swap lists the file's components.
  if (shell.inspector?.instanceId && !components.length) void loadAssets();
}

/** Layer `id`'s rotation on the canvas (its ancestors' included), in degrees, as Figma's
 * Rotation field shows it; null when the layer is not in the tree shown. */
export function canvasRotation(id: string): number | null {
  const i = tree.index.get(id);
  if (i === undefined) return null;
  return (Math.atan2(-tree.xf[i * 6 + 1], tree.xf[i * 6]) * 180) / Math.PI;
}

/** The selected nodes as the Design tab read them (up to 50). */
export const selectedInfos = (): NodeInfo[] => infos;

// ------------------------------------------------------------ following edits

export type DocChange = { why: ChangeWhy; ids: string[]; structure: boolean; vars: boolean };
const changeListeners = new Set<(c: DocChange) => void>();

/** Calls `fn` after every change to the document, once the panels and the marks show
 * it; returns the unsubscribe. */
export function onDocChange(fn: (c: DocChange) => void): () => void {
  changeListeners.add(fn);
  return () => changeListeners.delete(fn);
}

let hookedEditing: unknown = null;

/** Hooks the shell to the viewer's editing once it is there: the selection steps keep,
 * the selection undo puts back, and the change notices. */
function hookEditing(): void {
  const ed = viewerEditing();
  if (!ed || hookedEditing === ed) return;
  hookedEditing = ed;
  ed.selectionSource = () => shell.selection;
  ed.restoreSelection = (ids: string[]) => {
    const s = stage();
    // The tree is read again right after (docChanged), which drops ids that are gone.
    if (s && s.page !== treePage) pendingSelect = ids;
    else shell.selection = ids;
  };
  ed.onChange((out, why) => docChanged(out, why));
  ed.onSave = (state: string) => {
    if (state.startsWith("Not saved")) console.warn(state);
  };
}

/** Node properties whose edits leave every layer's id, name and guides as they were
 * (the layer tree is then read without them: a big page's names are most of it). */
const GEOMETRY_KEYS = new Set(["transform", "size", "fills", "strokes", "stroke", "effects", "opacity", "radius", "blend", "visible", "locked", "clip"]);
/** Node properties whose edits leave the layer tree as it was (only paints change). */
const PAINT_KEYS = new Set(["fills", "strokes"]);

function docChanged(out: EditOut, why: ChangeWhy): void {
  const ids: string[] = [];
  let structure = false;
  let vars = false;
  let geometry = !out.pages;
  // Colours alone (a colour variable or style and the layers following it): the layer
  // tree is as it was, only the Design tab reads again.
  let paints = !out.pages && why === "edit";
  for (const c of out.changes) {
    const ch = c.change as { op: string; node?: string; parent?: string; id?: string; props?: Record<string, unknown>; variable?: { type?: string } | null; style?: { type?: string } | null };
    if (ch.op === "variable" || ch.op === "collection") {
      vars = true;
      // A colour variable reaches only paints (guides follow number variables alone).
      if (ch.op !== "variable" || ch.variable?.type !== "color") geometry = paints = false;
      continue;
    }
    if (ch.node) ids.push(ch.node);
    if (ch.op !== "set" && ch.op !== "style") structure = true;
    // A style's value reaches the layers using it (their own sets follow); only a guide
    // style changes guides.
    if (ch.op === "style") {
      if (!ch.style || ch.style.type === "grid") geometry = false;
      if (ch.style?.type !== "fill") paints = false;
      continue;
    }
    if (ch.op !== "set" || !ch.props || !Object.keys(ch.props).every((k) => GEOMETRY_KEYS.has(k))) geometry = false;
    if (ch.op !== "set" || !ch.props || !Object.keys(ch.props).every((k) => PAINT_KEYS.has(k))) paints = false;
  }
  if (vars) varHooks.changed?.();
  if (out.pages) buildPages();
  if (paints && treePage >= 0 && tree.page === treePage) refreshInspector();
  else if (treePage >= 0) {
    const t = treeNow(treePage, geometry && why === "edit");
    if (t) {
      tree = t;
      // Layers that are gone leave the selection.
      const kept = shell.selection.filter((id) => tree.index.has(id));
      if (kept.length !== shell.selection.length) shell.selection = kept;
      if (shell.hover && !tree.index.has(shell.hover)) shell.hover = "";
      refreshRows();
      refreshInspector();
      shell.marks++;
    }
  }
  if (why === "undo" || why === "redo") reveal();
  const c: DocChange = { why, ids, structure, vars };
  for (const fn of changeListeners) {
    try {
      fn(c);
    } catch (err) {
      console.error("doc change", err);
    }
  }
}

// ------------------------------------------------------------ styles and assets

/** The local styles, by kind, folders ("Heading/H1") as rows that open. */
function buildStyles(): void {
  const kinds: [string, string][] = [
    ["text", "Text styles"],
    ["fill", "Color styles"],
    ["effect", "Effect styles"],
    ["grid", "Layout guide styles"],
  ];
  const groups: StyleGroup[] = [];
  for (const [kind, title] of kinds) {
    // In the file's order (the editor's), each folder where its first style is, holding
    // all of its styles (a later "Body/…" still goes under Body). Only the file's own:
    // a library's styles and deleted ones are left out.
    const list = styles.filter((s) => s.type === kind && s.own);
    if (!list.length) continue;
    type Folder = { folders: Map<string, Folder>; items: (StyleInfo | string)[] };
    const root: Folder = { folders: new Map(), items: [] };
    for (const s of list) {
      const parts = s.name.split("/").map((p) => p.trim());
      let at = root;
      for (const part of parts.slice(0, -1)) {
        let next = at.folders.get(part);
        if (!next) {
          next = { folders: new Map(), items: [] };
          at.folders.set(part, next);
          at.items.push(part);
        }
        at = next;
      }
      at.items.push(s);
    }
    const rows: StyleGroup["rows"] = [];
    const walk = (f: Folder, path: string, depth: number): void => {
      for (const item of f.items) {
        if (typeof item === "string") {
          const key = `${kind}:${path}${item}`;
          const open = styleOpen.has(key);
          rows.push({ key, name: item, detail: "", swatch: "", effect: "", kind, folder: true, depth, open });
          if (open) walk(f.folders.get(item) as Folder, `${path}${item}/`, depth + 1);
        } else {
          const name = item.name.split("/").pop()?.trim() ?? item.name;
          rows.push({ key: item.id, name, detail: item.detail, swatch: item.swatch, effect: item.effect, kind, folder: false, depth, open: false });
        }
      }
    };
    walk(root, "", 0);
    groups.push({ key: kind, title, rows });
  }
  shell.styles = groups;
}

export function toggleStyleFolder(key: string): void {
  if (styleOpen.has(key)) styleOpen.delete(key);
  else styleOpen.add(key);
  buildStyles();
}

/** Reads the file's components for Assets (once a file). */
export async function loadAssets(): Promise<void> {
  if (components.length || shell.assetsLoading || !shell.ready) return;
  shell.assetsLoading = true;
  try {
    components = await listComponents();
  } catch (err) {
    console.error("assets", err);
  }
  shell.assetsLoading = false;
  filterAssets();
}

export function filterAssets(): void {
  const q = shell.assetsQuery.trim().toLowerCase();
  shell.assets = components
    .filter((c) => c.kind === "set" || !c.set)
    .filter((c) => !q || c.name.toLowerCase().includes(q))
    .map((c) => ({ id: c.id, name: c.name, page: c.page, pageName: pageNames[c.page] ?? "", set: c.set, kind: c.kind }));
}

/** A link to layer `id` (`?node-id=`): the layer selected and filling the view, on
 * whichever page holds it (the pages not read yet are read one at a time until one does).
 * False when no page has it. */
export async function revealNode(id: string): Promise<boolean> {
  const e = viewerEditing()?.engine;
  if (!e) return false;
  const pageOf = (): number => {
    try {
      return e.nodeInfo(id).page ?? -1;
    } catch {
      return -1;
    }
  };
  let page = pageOf();
  const feed = feedOf(e);
  for (let i = 0; page < 0 && feed && i < livePages().length; i++) {
    if (e.pageFile(i).loaded) continue;
    await feed.page(i);
    page = pageOf();
  }
  if (page < 0) return false;
  if (page === treePage && tree.index.has(id)) {
    select([id]);
    zoomSelection();
  } else {
    pendingSelect = [id];
    pendingZoom = true;
    showPage(page);
  }
  return true;
}

viewerHooks.revealNode = revealNode;

/** The address names the selected layer (the page when none), as Figma's does, so the
 * link opens it. */
function followSelection(): void {
  const id = shell.selection[0] ?? currentPageId();
  if (!id || route.screen !== "file") return;
  const url = new URL(location.href);
  url.searchParams.set("node-id", id.replaceAll(":", "-"));
  history.replaceState(history.state, "", url);
}

/** An asset clicked: its page shows and the component is selected. */
export function revealAsset(id: string, page: number): void {
  if (page === treePage && tree.index.has(id)) {
    select([id]);
    zoomSelection();
    return;
  }
  pendingSelect = [id];
  showPage(page);
}

/** Go to main component: the main on its page, selected and filling the view, and a bar
 * to return to instance `instance`. */
export function showMain(instance: string, main: string, page: number): void {
  const from = treePage;
  const cam = stage()?.cam;
  if (page === treePage && tree.index.has(main)) {
    select([main]);
    zoomSelection();
  } else {
    pendingSelect = [main];
    pendingZoom = true;
    showPage(page);
  }
  shell.returnTo = { instance, page: from, mainPage: page };
  returnCam = cam ? { ...cam } : null;
}

/** Where the view was when Go to main component left the instance's page. */
let returnCam: { x: number; y: number; z: number } | null = null;

/** Return to instance: its page as it was left, the instance selected. */
export function returnToInstance(): void {
  const r = shell.returnTo;
  if (!r) return;
  shell.returnTo = null;
  if (r.page === treePage) {
    select([r.instance]);
    if (returnCam) stage()?.setCamera(returnCam);
    return;
  }
  // The page's own view comes back with it.
  pendingSelect = [r.instance];
  showPage(r.page);
}

export function closeReturn(): void {
  shell.returnTo = null;
}

/** The Return to instance bar shows: on the main's page. */
export function returnBarShown(): boolean {
  const r = shell.returnTo;
  return !!r && (Number(viewer.page) || 0) === r.mainPage;
}

export function setAssetsQuery(q: string): void {
  shell.assetsQuery = q;
  filterAssets();
}

// ------------------------------------------------------------ tools

export function setTool(tool: ToolName): void {
  shell.tool = tool;
  const s = stage();
  if (s) {
    s.handTool = tool === "hand";
    s.canvas.style.cursor = tool === "hand" ? "grab" : "";
  }
  if (tool !== "move") setHover("");
  if (tool === "move" || tool === "hand" || tool === "scale") shell.moveTool = tool;
  if (tool === "frame" || tool === "section" || tool === "slice") shell.frameTool = tool;
  if (["rectangle", "line", "arrow", "ellipse", "polygon", "star", "image"].includes(tool)) shell.shapeTool = tool;
  if (tool === "pen" || tool === "pencil") shell.penTool = tool;
}

export function toggleGuides(): void {
  shell.guides = !shell.guides;
  shell.marks++;
}

export function toggleRulers(): void {
  shell.rulers = !shell.rulers;
  shell.marks++;
}

// ------------------------------------------------------------ the canvas (the viewer)

/** The viewer's canvas (null until it mounts). */
export const stage = (): Stage | null => viewerStage();

export function zoomBy(f: number): void {
  const s = stage();
  if (s) s.zoomTo(s.cam.z * f);
}

export function zoomValue(z: number): void {
  stage()?.zoomTo(z);
}

export function zoomFit(): void {
  stage()?.fit();
}

/** Shift+2: the selection fills the view. */
export function zoomSelection(): void {
  const b = selectionBox();
  if (b) stage()?.showRect(b[0], b[1], b[2], b[3]);
  else zoomFit();
}

/** A page of the list: the canvas shows it (a page added here has nothing yet). */
export function showPage(index: number): void {
  choosePage(String(index));
}

/** The file's new name, from the name field. */
export function renameFile(event: Event): void {
  shell.renamingFile = false;
  void rename(event);
}

// ------------------------------------------------------------ following the viewer

let overlay: Overlay | null = null;

/** Copies what the viewer knows into the shell (run in an effect: it follows them). */
export function followViewer(): void {
  const id = viewer.fileId;
  const name = viewer.docName;
  const where = viewer.location;
  const page = Number(viewer.page) || 0;
  const pages = viewer.pages.length;
  const zoom = Number.parseFloat(viewer.zoom);
  untracked(() => {
    shell.zoomLabel = `${Number.isFinite(zoom) ? Math.round(zoom) : 100}%`;
    shell.fileName = name;
    shell.location = where;
    if (!id) {
      if (opened) closeShell();
      return;
    }
    if (pages && opened !== id) void openShell(id, where, name);
    const s = stage();
    hookEditing();
    shell.notSaved = !viewer.editsKept;
    if (s?.doc) buildPages();
    if (opened === id) void showTree(page);
  });
  overlay?.request();
}

/** Starts the canvas marks once the viewer's canvas is there. */
export function attachOverlay(area: HTMLElement): void {
  const s = stage();
  if (!s) {
    requestAnimationFrame(() => attachOverlay(area));
    return;
  }
  if (overlay) return;
  overlay = new Overlay(area, s);
  s.handTool = shell.tool === "hand";
}

/** The canvas's tools, once the marks are up (an editor shell beside the canvas hands
 * drags over through them). */
export function canvasTools(): Overlay["tools"] | null {
  return overlay?.tools ?? null;
}

/** The canvas marks redraw when the selection, hover, theme or rulers change. */
export function followMarks(): void {
  void shell.marks;
  void shell.dark;
  void shell.rulers;
  void shell.guides;
  overlay?.request();
}

const typing = (t: EventTarget | null) => t instanceof HTMLElement && (!!t.closest("input, textarea, select, [role=menu], [role=listbox]") || t.isContentEditable);

/** A right-click on the canvas at page point (x, y): what is there is selected first,
 * unless it is already (the menu then acts on the whole selection). */
export function canvasContext(event: MouseEvent): void {
  const s = stage();
  if (!s || shell.tool !== "move") return;
  const r = s.canvas.getBoundingClientRect();
  const x = s.cam.x + (event.clientX - r.left) / s.cam.z;
  const y = s.cam.y + (event.clientY - r.top) / s.cam.z;
  const id = targetAt(x, y, event.metaKey || event.ctrlKey);
  if (!id) select([]);
  else if (!shell.selection.includes(id)) select([id]);
}

/** The editor's own keys: the tools, Enter and Escape. The menus' keys are actions
 * (actions.ts `actionKey`, run first); the viewer handles Space, Shift+1, Shift+0, + and -
 * and Cmd+Z. */
export function onKey(e: KeyboardEvent): void {
  if (route.screen !== "file" || typing(e.target)) return;
  if (e.altKey) return;
  const mod = e.metaKey || e.ctrlKey;
  if (mod) return;
  const k = e.key.toLowerCase();
  const tools: Record<string, ToolName> = { v: "move", h: "hand", k: "scale", f: "frame", s: "slice", r: "rectangle", o: "ellipse", l: "line", p: "pen", t: "text", c: "comment" };
  const shifted: Record<string, ToolName> = { s: "section", l: "arrow", p: "pencil" };
  if (e.shiftKey && shifted[k]) {
    e.preventDefault();
    setTool(shifted[k]);
  } else if (!e.shiftKey && tools[k]) {
    e.preventDefault();
    setTool(tools[k]);
  } else if (e.key === "Enter") {
    e.preventDefault();
    if (e.shiftKey) selectParent();
    else selectChildren();
  } else if (e.key === "Escape") {
    selectParent();
  }
}
