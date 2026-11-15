// The variables, as the editor shows and edits them: the Variables window (its
// collections, groups, the table of variables with a column a mode, the value cells,
// the edit popover and the pickers) and what the Design tab adds for a selection (the
// fields bound to variables, the modes a layer sets). The window's parts render the
// `vars` store only; the document's variables are read from the engine on the canvas's
// thread (`Engine.variables`, `variableTable`, `nodeModes`) and every change is a Pubd
// `variable` or `collection` change (or a node's `vars` and `modes`) applied through
// edits.ts, one undo step each (pubd/SPEC.md "Variables").

import { Publr } from "publr-jsx";
import { liveEngine } from "./doc";
import type { NodeInfo } from "./doc";
import { apply, begin, commit, patchPaint, panelPaints } from "./edits";
import type { PaintList } from "./edits";
import { colorOf, num } from "./inspector";
import type { Inspector } from "./inspector";
import { hexOf, rgbToHsv } from "./picker";
import { onDocChange, selectedInfos, shell, varHooks } from "./store";

// ------------------------------------------------------------ the document's variables

export type VarType = "color" | "number" | "string" | "boolean";

type RawMode = { id: string; name: string; parent?: string };
type RawCol = { id: string; name: string; modes: RawMode[]; library?: boolean; key?: string; hidden?: boolean; parent?: string; overrides?: Record<string, Record<string, unknown>>; deleted?: boolean };
type RawVar = {
  id: string;
  name: string;
  collection: string;
  type: VarType;
  values: Record<string, unknown>;
  description?: string;
  scopes?: string[];
  code?: { web?: string; ios?: string; android?: string };
  hidden?: boolean;
  key?: string;
  deleted?: boolean;
};

let cols: RawCol[] = [];
let list: RawVar[] = [];
const byId = new Map<string, RawVar>();
const byKey = new Map<string, RawVar>();
const colById = new Map<string, RawCol>();
/** The engine the lists were read from, and whether they are stale. */
let readFrom: unknown = null;
let stale = true;
/** Every variable's worth in the default modes (the pickers' swatches), when read. */
let defaults: Record<string, unknown[]> | null = null;

/** Reads the variables again when the document or its variables changed. */
function ensure(): boolean {
  const e = liveEngine();
  if (!e) {
    cols = [];
    list = [];
    byId.clear();
    byKey.clear();
    colById.clear();
    readFrom = null;
    return false;
  }
  if (readFrom === e && !stale) return true;
  try {
    const r = e.variables();
    cols = r.collections as unknown as RawCol[];
    list = r.variables as unknown as RawVar[];
  } catch (err) {
    console.error("variables", err);
    cols = [];
    list = [];
  }
  byId.clear();
  byKey.clear();
  colById.clear();
  for (const v of list) {
    byId.set(v.id, v);
    if (v.key) byKey.set(v.key, v);
  }
  for (const c of cols) colById.set(c.id, c);
  readFrom = e;
  stale = false;
  defaults = null;
  return true;
}

/** The variable a reference names (an id, or `key:<library key>`). */
function lookup(ref: string): RawVar | null {
  return byId.get(ref) ?? (ref.startsWith("key:") ? (byKey.get(ref.slice(4).split("@")[0]) ?? null) : null);
}

const leaf = (name: string) => name.split("/").pop()?.trim() ?? name;
const groupOf = (name: string) => {
  const parts = name.split("/");
  parts.pop();
  return parts.map((p) => p.trim()).join("/");
};

/** A reference's name as a pill shows it (its last part). */
export function varName(ref: string): string {
  ensure();
  const v = lookup(ref);
  return v ? leaf(v.name) : ref.startsWith("key:") ? Publr.t("Library variable") : Publr.t("Missing variable");
}

/** A reference's whole name ("Colors/Background/bg-primary"), as the Design tab names a
 * bound paint and a bound field's pill on hover. */
export function varPath(ref: string): string {
  ensure();
  const v = lookup(ref);
  return v ? v.name : ref.startsWith("key:") ? Publr.t("Library variable") : Publr.t("Missing variable");
}

/** A local collection: not copied from a library (nor removed: one kept only because
 * layers still use its variables is not listed). */
const local = (c: RawCol) => !c.library && !c.deleted;

let seq = 0;
/** A new id no other variable, collection or mode has. */
function newId(prefix: string): string {
  for (;;) {
    const id = `${prefix}:${Date.now().toString(36)}${(seq++).toString(36)}`;
    if (!byId.has(id) && !colById.has(id)) return id;
  }
}

/** A variable as a change carries it (no id). */
function bodyOf(v: RawVar): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  for (const k of Object.keys(v)) if (k !== "id") out[k] = (v as unknown as Record<string, unknown>)[k];
  return out;
}

function colBody(c: RawCol): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  for (const k of Object.keys(c)) if (k !== "id") out[k] = (c as unknown as Record<string, unknown>)[k];
  return out;
}

const varChange = (v: RawVar, index?: number) => (index === undefined ? { op: "variable", id: v.id, variable: bodyOf(v) } : { op: "variable", id: v.id, variable: bodyOf(v), index });
const removeVar = (id: string) => ({ op: "variable", id, variable: null });
const colChange = (c: RawCol, index?: number) => (index === undefined ? { op: "collection", id: c.id, collection: colBody(c) } : { op: "collection", id: c.id, collection: colBody(c), index });

const copy = <T>(x: T): T => JSON.parse(JSON.stringify(x)) as T;

// ------------------------------------------------------------ the window's store

export type Cell = {
  mode: string;
  /** "color", "alias", "number", "string", "boolean", "none". */
  kind: string;
  /** The value as shown: hex (no #), the number, the text. */
  text: string;
  /** CSS of the swatch (colours and colour aliases), and the colour without its
   * opacity (a translucent swatch's left half). */
  swatch: string;
  solid: string;
  /** The colour's opacity ("" at 100%). */
  alpha: string;
  on: boolean;
  /** An alias: the aliased variable's name, and its full name. */
  alias: string;
  aliasPath: string;
  /** Being typed; its opacity being typed. */
  editing: boolean;
  alphaEditing: boolean;
};

export type VarRow = {
  key: string;
  /** Its place in the list, and its top in the table (px). */
  at: number;
  top: number;
  kind: "var" | "group";
  id: string;
  /** A variable's own name; a group's path as shown (its last part apart). */
  name: string;
  /** A group header's path before its last part ("Colors / "), "" for none. */
  prefix: string;
  type: VarType;
  /** A colour variable's first value (the name's swatch). */
  swatch: string;
  selected: boolean;
  renaming: boolean;
  dropAbove: boolean;
  dropBelow: boolean;
  cells: Cell[];
};

export type ColRow = { id: string; name: string; count: number; selected: boolean; renaming: boolean };
export type GroupRow = { key: string; path: string; name: string; depth: number; count: number; selected: boolean; folder: boolean; open: boolean; renaming: boolean };
export type TypeFilter = "" | VarType;
export type ModeCol = { id: string; name: string; renaming: boolean; first: boolean };
export type PickItem = { key: string; head: boolean; id: string; name: string; path: string; type: VarType; swatch: string; value: string; current: boolean };
export type ScopeRow = { key: string; label: string; on: boolean; indent: boolean };

/** The height of a variable's row and of a group's header row, their bottom line in. */
export const ROW = 41;
export const GROUP_ROW = 57;

export const vars = Publr.reactive({
  open: false,
  /** Maximised (everything but the rail: the file's name, collections and groups on the
   * left, the table on the right) or a window over the canvas. */
  full: false,
  /** Maximised: the left side shown (its panel button hides it). */
  side: true,
  /** The table shows variables of this type only ("" every type). */
  typeFilter: "" as TypeFilter,
  x: 0,
  y: 0,
  winW: 960,
  winH: 600,
  collections: [] as ColRow[],
  /** The collection shown. */
  collection: "",
  collectionName: "",
  /** The collections list's drop line while one is dragged (its top, px; -1 none). */
  colDrop: -1,
  /** A library or extended collection: shown, not changed here. */
  readOnly: false,
  groups: [] as GroupRow[],
  /** The group shown ("" all). */
  group: "",
  allCount: 0,
  modes: [] as ModeCol[],
  /** The name column and a mode's column, their divider in (px). */
  nameW: 201,
  modeW: 281,
  rows: [] as VarRow[],
  /** The table's whole height. */
  height: 0,
  query: "",
  searching: false,
  /** Nothing to show: no collection, or none matches. */
  empty: false,
  /** The edit popover ("" closed): the variable's id. */
  edit: "",
  editTop: 0,
  editLeft: 0,
  /** The popover's height at most (it scrolls past it). */
  editMax: 600,
  editName: "",
  editType: "color" as VarType,
  editDescription: "",
  editAll: true,
  editScopes: [] as ScopeRow[],
  editCode: { web: "", ios: "", android: "" },
  editCodeOpen: false,
  editHidden: false,
  /** The colour picker on a cell: open, where, and the colour. */
  color: false,
  colorTop: 0,
  colorLeft: 0,
  hue: 0,
  sat: 0,
  bright: 0,
  alpha: 1,
  hex: "000000",
  /** The variable picker (aliasing a value, binding a field). */
  pick: false,
  pickTop: 0,
  pickLeft: 0,
  pickTitle: "",
  pickQuery: "",
  pickItems: [] as PickItem[],
  /** The Design tab: the file has collections with several modes. */
  anyModes: false,
});

/** The variable rows shown (all of them; only a window is drawn). */
type Entry = { kind: "group"; path: string } | { kind: "var"; v: RawVar };
let flat: Entry[] = [];
/** Each entry's top in the table (px), and one past the last: the table's height. */
let tops: number[] = [0];
let table: Record<string, unknown[]> = {};
const selected = new Set<string>();
let anchor = "";
let renaming = "";
let renamingCol = "";
let renamingGroup = "";
let renamingMode = "";
let editing = "";
const openGroups = new Set<string>();
/** Maximised, every group is open but the ones closed here. */
const closedGroups = new Set<string>();
let viewTop = 0;
let viewHeight = 600;
let scroller: HTMLElement | null = null;
/** A row dragged: the ids, and where they would land. */
let dragIds: string[] = [];
let dropAt: { before: string; after: string } | null = null;

const shownCol = () => colById.get(vars.collection) ?? null;

/** The variables collection `c` shows (its parent's for an extended one). */
function varsOf(c: RawCol): RawVar[] {
  const owner = c.parent ?? c.id;
  return list.filter((v) => v.collection === owner && !v.deleted);
}

/** Opens the window (or closes it). */
export function toggleVariables(): void {
  if (vars.open) closeVariables();
  else openVariables();
}

export function openVariables(): void {
  if (!ensure()) return;
  if (!vars.open) {
    const area = document.querySelector("[data-pd-canvas]")?.getBoundingClientRect();
    const w = Math.min(960, Math.max(640, (area?.width ?? 1000) - 48));
    const h = Math.min(600, Math.max(400, (area?.height ?? 700) - 96));
    vars.winW = w;
    vars.winH = h;
    vars.x = Math.round((area?.left ?? 0) + ((area?.width ?? w) - w) / 2);
    vars.y = Math.round((area?.top ?? 0) + Math.max(24, ((area?.height ?? h) - h) / 2));
  }
  vars.open = true;
  if (!colById.has(vars.collection) || !local(colById.get(vars.collection)!)) vars.collection = cols.find(local)?.id ?? "";
  rebuild();
}

export function closeVariables(): void {
  vars.open = false;
  closePopovers();
}

/** A press outside the popovers closes them (a press on what opens one opens it). */
if (typeof document !== "undefined")
  document.addEventListener(
    "pointerdown",
    (e) => {
      if (!vars.edit && !vars.color && !vars.pick) return;
      const t = e.target instanceof Element ? e.target : null;
      if (!t || t.closest("[data-part=floating-panel], [role=menu], [data-pd-var-edit], [data-pd-cell-value], [data-pd-alias-button], [data-pd-field-apply], [data-pd-field-var], [data-pd-paint-var], [data-pd-swatch], [data-pd-button=styles]")) return;
      closePopovers();
      closePick();
    },
    true,
  );

export function closePopovers(): void {
  vars.edit = "";
  vars.color = false;
  if (pickFor?.kind === "alias") vars.pick = false;
  editing = "";
}

/** The window's place before it was expanded. */
let before = { x: 0, y: 0, w: 960, h: 600 };

/** Expanded over the whole canvas, or back to the window it was. */
export function toggleFull(): void {
  if (vars.full) {
    vars.full = false;
    vars.x = before.x;
    vars.y = before.y;
    vars.winW = before.w;
    vars.winH = before.h;
    rebuild();
    return;
  }
  before = { x: vars.x, y: vars.y, w: vars.winW, h: vars.winH };
  // Everything right of the rail, from the workspace's top to the bottom (the window
  // keeps to the page's right and bottom edges as it is resized).
  const rail = document.querySelector("[data-pd-rail]")?.getBoundingClientRect();
  const area = document.querySelector("[data-pd-workspace]")?.getBoundingClientRect();
  if (!area) return;
  vars.full = true;
  vars.side = true;
  vars.x = Math.round(rail ? rail.right : area.left);
  vars.y = Math.round(area.top);
  rebuild();
}

/** Maximised: the left side (collections and groups) hidden or shown. */
export function toggleSide(): void {
  vars.side = !vars.side;
}

/** Maximised: every group closed, or (none open) every group open. */
export function toggleAllGroups(): void {
  const c = shownCol();
  const folders = new Set<string>();
  for (const v of c ? varsOf(c) : []) {
    const parts = groupOf(v.name).split("/");
    for (let k = 1; k < parts.length; k++) folders.add(parts.slice(0, k).join("/"));
  }
  const anyOpen = [...folders].some((f) => !closedGroups.has(f));
  closedGroups.clear();
  if (anyOpen) for (const f of folders) closedGroups.add(f);
  rebuild();
}

export function setTypeFilter(t: TypeFilter): void {
  vars.typeFilter = t;
  if (scroller) scroller.scrollTop = 0;
  viewTop = 0;
  rebuild();
}

/** Everything the window shows, read again. */
function rebuild(): void {
  if (!vars.open) return;
  ensure();
  const c = shownCol();
  vars.collections = cols.filter(local).map((x) => ({ id: x.id, name: x.name || Publr.t("Collection"), count: varsOf(x).length, selected: x.id === vars.collection, renaming: renamingCol === x.id }));
  vars.collectionName = c?.name ?? "";
  vars.readOnly = !c || !!c.library || !!c.parent;
  vars.modes = (c?.modes ?? []).map((m, k) => ({ id: m.id, name: m.name || `Mode ${k + 1}`, renaming: renamingMode === m.id, first: k === 0 }));
  try {
    table = c ? (liveEngine()?.variableTable(c.id) ?? {}) : {};
  } catch (err) {
    console.error("variables table", err);
    table = {};
  }
  buildGroups(c);
  buildFlat(c);
  drawRows();
}

/** The sidebar's groups: a tree of the names' folders, each with how many it holds. */
function buildGroups(c: RawCol | null): void {
  const all = c ? varsOf(c) : [];
  vars.allCount = all.length;
  type Folder = { kids: Map<string, Folder>; count: number };
  const root: Folder = { kids: new Map(), count: 0 };
  for (const v of all) {
    const g = groupOf(v.name);
    if (!g) continue;
    let at = root;
    for (const part of g.split("/")) {
      let next = at.kids.get(part);
      if (!next) {
        next = { kids: new Map(), count: 0 };
        at.kids.set(part, next);
      }
      next.count++;
      at = next;
    }
  }
  const rows: GroupRow[] = [];
  const walk = (f: Folder, path: string, depth: number) => {
    for (const [name, sub] of f.kids) {
      const p = path ? `${path}/${name}` : name;
      const open = vars.full ? !closedGroups.has(p) : openGroups.has(p) || vars.group === p || vars.group.startsWith(`${p}/`);
      rows.push({ key: p, path: p, name, depth, count: sub.count, selected: vars.group === p, folder: sub.kids.size > 0, open, renaming: renamingGroup === p });
      if (open) walk(sub, p, depth + 1);
    }
  };
  walk(root, "", 0);
  if (vars.group && !rows.some((r) => r.path === vars.group) && !all.some((v) => groupOf(v.name).startsWith(vars.group))) vars.group = "";
  vars.groups = rows;
}

/** The table's rows: the group's variables (all of them, or those the search finds),
 * each group's under a header, groups in the order their first variable has. */
function buildFlat(c: RawCol | null): void {
  const q = vars.query.trim().toLowerCase();
  const g = vars.group;
  type Folder = { vars: RawVar[]; kids: Map<string, Folder> };
  const root: Folder = { vars: [], kids: new Map() };
  for (const v of c ? varsOf(c) : []) {
    const path = groupOf(v.name);
    if (g && path !== g && !path.startsWith(`${g}/`)) continue;
    if (q && !v.name.toLowerCase().includes(q)) continue;
    if (vars.typeFilter && v.type !== vars.typeFilter) continue;
    let at = root;
    if (path)
      for (const part of path.split("/")) {
        let next = at.kids.get(part);
        if (!next) {
          next = { vars: [], kids: new Map() };
          at.kids.set(part, next);
        }
        at = next;
      }
    at.vars.push(v);
  }
  const out: Entry[] = [];
  const walk = (f: Folder, path: string) => {
    if (f.vars.length) {
      // The group shown has no header of its own; its subgroups do (their path in it).
      if (path && path !== g) out.push({ kind: "group", path });
      for (const v of f.vars) out.push({ kind: "var", v });
    }
    for (const [name, sub] of f.kids) walk(sub, path ? `${path}/${name}` : name);
  };
  walk(root, "");
  flat = out;
  tops = [0];
  for (const e of flat) tops.push(tops[tops.length - 1] + (e.kind === "group" ? GROUP_ROW : ROW));
  vars.height = tops[flat.length];
  vars.empty = flat.length === 0;
  for (const id of [...selected]) if (!byId.has(id)) selected.delete(id);
}

/** A value as the table shows it. */
function cellOf(v: RawVar, k: number, mode: RawMode, c: RawCol): Cell {
  const first = c.modes[0]?.id ?? "";
  let raw: unknown = v.values[mode.id];
  if (c.parent) raw = c.overrides?.[v.id]?.[mode.id] ?? v.values[mode.parent ?? ""] ?? v.values[first];
  if (raw === undefined) raw = v.values[first];
  const resolved = table[v.id]?.[k];
  const cell: Cell = { mode: mode.id, kind: "none", text: "", swatch: "", solid: "", alpha: "", on: false, alias: "", aliasPath: "", editing: editing === `${v.id}|${mode.id}`, alphaEditing: editing === `${v.id}|${mode.id}|a` };
  if (raw && typeof raw === "object" && !Array.isArray(raw) && "alias" in (raw as Record<string, unknown>)) {
    const ref = String((raw as { alias: string }).alias);
    const target = lookup(ref);
    cell.kind = "alias";
    cell.alias = target ? target.name : Publr.t("Missing variable");
    cell.aliasPath = target ? `${colById.get(target.collection)?.name ?? ""} / ${target.name}` : ref;
    if (v.type === "color" && resolved !== null && resolved !== undefined) cell.swatch = colorCss(resolved);
    cell.text = shown(v.type, resolved);
    return cell;
  }
  if (v.type === "color") {
    const val = raw && typeof raw === "object" && !Array.isArray(raw) && "compose" in (raw as Record<string, unknown>) ? resolved : raw;
    const col = colorOf(colorPart(val));
    cell.kind = "color";
    cell.text = col.hex;
    cell.swatch = colorCss(val);
    cell.solid = `#${col.hex}`;
    const a = col.alpha * opacityPart(val);
    cell.alpha = a < 0.9995 ? `${num(Math.round(a * 100))}%` : "";
    return cell;
  }
  if (v.type === "boolean") {
    cell.kind = "boolean";
    cell.on = raw === true;
    cell.text = raw === true ? "true" : "false";
    return cell;
  }
  cell.kind = v.type;
  cell.text = v.type === "number" ? (typeof raw === "number" ? num(raw) : shown("number", resolved)) : typeof raw === "string" ? raw : shown("string", resolved);
  return cell;
}

const colorPart = (val: unknown): unknown => (val && typeof val === "object" && !Array.isArray(val) && "color" in (val as Record<string, unknown>) ? (val as { color: unknown }).color : val);
const opacityPart = (val: unknown): number => (val && typeof val === "object" && !Array.isArray(val) && "opacity" in (val as Record<string, unknown>) ? Number((val as { opacity: number }).opacity) : 1);

function colorCss(val: unknown): string {
  const c = colorOf(colorPart(val));
  const a = c.alpha * opacityPart(val);
  return `rgba(${parseInt(c.hex.slice(0, 2), 16)},${parseInt(c.hex.slice(2, 4), 16)},${parseInt(c.hex.slice(4, 6), 16)},${a})`;
}

/** A resolved value as text. */
function shown(type: VarType, val: unknown): string {
  if (val === null || val === undefined) return "";
  if (type === "color") return colorOf(colorPart(val)).hex;
  if (type === "number") return typeof val === "number" ? num(val) : String(val);
  return String(val);
}

/** The rows in view (and a few around them). */
function drawRows(): void {
  const c = shownCol();
  const first = Math.max(0, entryAt(viewTop) - 4);
  const last = Math.min(flat.length, entryAt(viewTop + viewHeight) + 5);
  const rows: VarRow[] = [];
  for (let at = first; at < last; at++) {
    const e = flat[at];
    if (e.kind === "group") {
      const rel = (vars.group && e.path.startsWith(`${vars.group}/`) ? e.path.slice(vars.group.length + 1) : e.path).split("/");
      const name = rel.pop() ?? "";
      rows.push({ key: `g:${e.path}`, at, top: tops[at], kind: "group", id: e.path, name, prefix: rel.length ? `${rel.join(" / ")} / ` : "", type: "color", swatch: "", selected: false, renaming: false, dropAbove: false, dropBelow: false, cells: [] });
      continue;
    }
    const v = e.v;
    const cells = c ? c.modes.map((m, k) => cellOf(v, k, m, c)) : [];
    rows.push({
      key: v.id,
      at,
      top: tops[at],
      kind: "var",
      id: v.id,
      name: leaf(v.name),
      prefix: "",
      type: v.type,
      swatch: v.type === "color" ? (cells[0]?.swatch ?? "") : "",
      selected: selected.has(v.id),
      renaming: renaming === v.id,
      dropAbove: !!dropAt && dropAt.before === v.id,
      dropBelow: !!dropAt && dropAt.after === v.id,
      cells,
    });
  }
  vars.rows = rows;
}

/** The entry at `y` px down the table (the last one past its end). */
function entryAt(y: number): number {
  let lo = 0;
  let hi = flat.length;
  while (lo < hi) {
    const mid = (lo + hi) >> 1;
    if (tops[mid + 1] <= y) lo = mid + 1;
    else hi = mid;
  }
  return lo;
}

/** The table's scroller: its position and height decide the rows drawn. */
export const tableScroller = Publr.ref((el: HTMLElement) => {
  scroller = el;
  const update = () => {
    viewTop = el.scrollTop;
    viewHeight = el.clientHeight;
    drawRows();
  };
  el.addEventListener("scroll", update, { passive: true });
  const ro = new ResizeObserver(update);
  ro.observe(el);
  update();
  return () => {
    el.removeEventListener("scroll", update);
    ro.disconnect();
    if (scroller === el) scroller = null;
  };
});

// ------------------------------------------------------------ following the document

varHooks.changed = () => {
  stale = true;
};

onDocChange((c) => {
  if (!c.vars && c.why !== "undo" && c.why !== "redo") return;
  stale = true;
  if (vars.open) {
    ensure();
    if (vars.collection && !colById.has(vars.collection)) vars.collection = cols.find(local)?.id ?? "";
    rebuild();
    if (vars.edit) readEdit();
    if (vars.color && (c.why === "undo" || c.why === "redo")) readColor();
  }
  if (vars.pick && pickFor) buildPick();
});

// ------------------------------------------------------------ collections

export function showCollection(id: string): void {
  if (vars.collection === id || suppressColClick) return;
  vars.collection = id;
  vars.group = "";
  selected.clear();
  closePopovers();
  if (scroller) scroller.scrollTop = 0;
  viewTop = 0;
  rebuild();
}

/** A name not taken among `names`: `base`, else "base 2", "base 3"... */
function freeName(base: string, names: string[]): string {
  const taken = new Set(names);
  if (!taken.has(base)) return base;
  for (let n = 2; ; n++) if (!taken.has(`${base} ${n}`)) return `${base} ${n}`;
}

export function createCollection(): void {
  ensure();
  const id = newId("VariableCollectionId");
  const c: RawCol = { id, name: freeName(Publr.t("Collection"), cols.map((x) => x.name)), modes: [{ id: newId("m"), name: Publr.t("Mode 1") }] };
  if (!apply([colChange(c)])) return;
  vars.collection = id;
  vars.group = "";
  renamingCol = id;
  rebuild();
}

export function startRenameCollection(id: string): void {
  renamingCol = id;
  rebuild();
}

export function renameCollection(id: string, name: string | null): void {
  if (renamingCol !== id) return;
  renamingCol = "";
  const c = colById.get(id);
  if (c && name !== null && name.trim() && name.trim() !== c.name) apply([colChange({ ...c, name: name.trim() })]);
  rebuild();
}

export function deleteCollection(id: string): void {
  ensure();
  const c = colById.get(id);
  if (!c) return;
  const changes: unknown[] = list.filter((v) => v.collection === id).map((v) => removeVar(v.id));
  changes.push({ op: "collection", id, collection: null });
  if (!apply(changes as Record<string, unknown>[])) return;
  if (vars.collection === id) vars.collection = "";
  ensure();
  if (!vars.collection) vars.collection = cols.find(local)?.id ?? "";
  rebuild();
}

export function duplicateCollection(id: string): void {
  ensure();
  const c = colById.get(id);
  if (!c) return;
  const nc: RawCol = copy(c);
  nc.id = newId("VariableCollectionId");
  nc.name = freeName(`${c.name} copy`, cols.map((x) => x.name));
  delete nc.key;
  delete nc.library;
  const ids = new Map<string, string>();
  const own = list.filter((v) => v.collection === id);
  for (const v of own) ids.set(v.id, newId("VariableID"));
  const changes: Record<string, unknown>[] = [colChange(nc, cols.indexOf(c) + 1)];
  for (const v of own) {
    const nv: RawVar = copy(v);
    nv.id = ids.get(v.id)!;
    nv.collection = nc.id;
    delete nv.key;
    // Aliases inside the collection point at the copies.
    for (const m of Object.keys(nv.values)) {
      const val = nv.values[m] as { alias?: string } | undefined;
      if (val && typeof val === "object" && val.alias && ids.has(val.alias)) nv.values[m] = { alias: ids.get(val.alias) };
    }
    changes.push(varChange(nv));
  }
  if (apply(changes)) showCollection(nc.id);
}

/** A press on a collection: past a few pixels it drags it up or down the list (the line
 * shows where it lands), release moves it there. */
export function collectionPointerDown(id: string, event: PointerEvent): void {
  if (event.button !== 0 || renamingCol) return;
  const list = (event.currentTarget as HTMLElement).closest("[data-pd-collections]") as HTMLElement | null;
  if (!list) return;
  const y0 = event.clientY;
  let dragging = false;
  let before = "";
  const rows = () => [...list.querySelectorAll<HTMLElement>("[data-pd-collection-row]")];
  const move = (e: PointerEvent) => {
    if (!dragging) {
      if (Math.abs(e.clientY - y0) < 4) return;
      dragging = true;
      document.body.style.cursor = "grabbing";
    }
    const rs = rows();
    const at = rs.findIndex((r) => {
      const b = r.getBoundingClientRect();
      return e.clientY < b.top + b.height / 2;
    });
    before = at < 0 ? "" : (rs[at].dataset.pdCollectionRow ?? "");
    const lb = list.getBoundingClientRect();
    const ref = at < 0 ? rs[rs.length - 1]?.getBoundingClientRect().bottom : rs[at].getBoundingClientRect().top;
    vars.colDrop = ref === undefined ? -1 : ref - lb.top + list.scrollTop;
  };
  const up = () => {
    window.removeEventListener("pointermove", move, true);
    window.removeEventListener("pointerup", up, true);
    document.body.style.cursor = "";
    vars.colDrop = -1;
    if (!dragging) return;
    suppressColClick = true;
    setTimeout(() => (suppressColClick = false), 0);
    moveCollection(id, before);
  };
  window.addEventListener("pointermove", move, true);
  window.addEventListener("pointerup", up, true);
}

let suppressColClick = false;

/** Collection `id` moved before `before` ("" the end). */
export function moveCollection(id: string, before: string): void {
  ensure();
  const c = colById.get(id);
  if (!c || id === before) return;
  let to = before ? cols.findIndex((x) => x.id === before) : cols.length;
  const from = cols.indexOf(c);
  if (to < 0) return;
  if (to > from) to--;
  if (to === from) return;
  apply([colChange(c, to)]);
}

// ------------------------------------------------------------ modes

export function addMode(): void {
  ensure();
  const c = shownCol();
  if (!c || vars.readOnly) return;
  const mode = { id: newId("m"), name: freeName(`Mode ${c.modes.length + 1}`, c.modes.map((m) => m.name)) };
  const first = c.modes[0]?.id ?? "";
  // The new mode starts with the default mode's values, as in the editor.
  const changes: Record<string, unknown>[] = [colChange({ ...c, modes: [...c.modes, mode] })];
  for (const v of varsOf(c))
    if (v.values[first] !== undefined) changes.push(varChange({ ...v, values: { ...v.values, [mode.id]: copy(v.values[first]) } }));
  if (!apply(changes)) return;
  renamingMode = mode.id;
  rebuild();
  // The new column shows: the table scrolls to its end.
  requestAnimationFrame(() => {
    if (scroller) scroller.scrollLeft = scroller.scrollWidth;
  });
}

export function startRenameMode(id: string): void {
  if (vars.readOnly) return;
  renamingMode = id;
  rebuild();
}

export function renameMode(id: string, name: string | null): void {
  if (renamingMode !== id) return;
  renamingMode = "";
  const c = shownCol();
  const m = c?.modes.find((x) => x.id === id);
  if (c && m && name !== null && name.trim() && name.trim() !== m.name) apply([colChange({ ...c, modes: c.modes.map((x) => (x.id === id ? { ...x, name: name.trim() } : x)) })]);
  rebuild();
}

export function deleteMode(id: string): void {
  const c = shownCol();
  if (!c || c.modes.length <= 1 || vars.readOnly) return;
  const changes: Record<string, unknown>[] = [colChange({ ...c, modes: c.modes.filter((m) => m.id !== id) })];
  for (const v of varsOf(c))
    if (id in v.values) {
      const values = { ...v.values };
      delete values[id];
      changes.push(varChange({ ...v, values }));
    }
  apply(changes);
}

export function duplicateMode(id: string): void {
  const c = shownCol();
  const m = c?.modes.find((x) => x.id === id);
  if (!c || !m || vars.readOnly) return;
  const mode = { id: newId("m"), name: freeName(`${m.name} copy`, c.modes.map((x) => x.name)) };
  const at = c.modes.indexOf(m) + 1;
  const modes = [...c.modes.slice(0, at), mode, ...c.modes.slice(at)];
  const changes: Record<string, unknown>[] = [colChange({ ...c, modes })];
  for (const v of varsOf(c)) if (v.values[id] !== undefined) changes.push(varChange({ ...v, values: { ...v.values, [mode.id]: copy(v.values[id]) } }));
  apply(changes);
}

/** Mode `id` first: the collection's default. */
export function makeDefaultMode(id: string): void {
  moveMode(id, 0);
}

/** Mode `id` to place `to` (0 the default). */
export function moveMode(id: string, to: number): void {
  const c = shownCol();
  const m = c?.modes.find((x) => x.id === id);
  if (!c || !m || vars.readOnly) return;
  const rest = c.modes.filter((x) => x.id !== id);
  rest.splice(Math.max(0, Math.min(rest.length, to)), 0, m);
  if (rest.every((x, k) => x.id === c.modes[k].id)) return;
  apply([colChange({ ...c, modes: rest })]);
}

// ------------------------------------------------------------ groups

export function showGroup(path: string): void {
  vars.group = path;
  selected.clear();
  closePopovers();
  if (scroller) scroller.scrollTop = 0;
  viewTop = 0;
  rebuild();
}

export function toggleGroup(path: string, event?: MouseEvent): void {
  event?.stopPropagation();
  const set = vars.full ? closedGroups : openGroups;
  if (set.has(path)) set.delete(path);
  else set.add(path);
  rebuild();
}

/** Every variable named under `path` renamed by `rename`, as one step. */
function renameUnder(path: string, rename: (name: string) => string): boolean {
  const c = shownCol();
  if (!c) return false;
  const changes = varsOf(c)
    .filter((v) => groupOf(v.name) === path || groupOf(v.name).startsWith(`${path}/`))
    .map((v) => varChange({ ...v, name: rename(v.name) }))
    .filter((ch) => (ch.variable as { name: string }).name !== byId.get(ch.id)?.name);
  return apply(changes);
}

export function startRenameGroup(path: string): void {
  if (vars.readOnly) return;
  renamingGroup = path;
  rebuild();
}

export function renameGroup(path: string, name: string | null): void {
  if (renamingGroup !== path) return;
  renamingGroup = "";
  const clean = name?.trim().replace(/\//g, "-") ?? "";
  if (name !== null && clean && clean !== leaf(path)) {
    const parent = groupOf(path);
    const to = parent ? `${parent}/${clean}` : clean;
    if (renameUnder(path, (n) => to + n.slice(path.length))) {
      if (vars.group === path || vars.group.startsWith(`${path}/`)) vars.group = to + vars.group.slice(path.length);
    }
  }
  rebuild();
}

/** The group goes; what it held moves up a level. */
export function ungroup(path: string): void {
  const parent = groupOf(path);
  if (renameUnder(path, (n) => (parent ? `${parent}/` : "") + n.slice(path.length + 1))) {
    if (vars.group === path) vars.group = parent;
  }
  rebuild();
}

export function deleteGroup(path: string): void {
  const c = shownCol();
  if (!c) return;
  apply(varsOf(c).filter((v) => groupOf(v.name) === path || groupOf(v.name).startsWith(`${path}/`)).map((v) => removeVar(v.id)));
  if (vars.group === path || vars.group.startsWith(`${path}/`)) vars.group = groupOf(path);
  rebuild();
}

/** The selected variables go into a new group where they are. */
export function groupSelection(): void {
  const c = shownCol();
  if (!c || !selected.size) return;
  const picked = varsOf(c).filter((v) => selected.has(v.id));
  const base = groupOf(picked[0].name);
  const groups = new Set(varsOf(c).map((v) => groupOf(v.name)));
  const prefix = base ? `${base}/` : "";
  let name = Publr.t("New group");
  for (let n = 2; groups.has(prefix + name); n++) name = `${Publr.t("New group")} ${n}`;
  const to = prefix + name;
  if (!apply(picked.map((v) => varChange({ ...v, name: `${to}/${leaf(v.name)}` })))) return;
  openGroups.add(to);
  renamingGroup = to;
  rebuild();
}

// ------------------------------------------------------------ variables

const TYPE_NAMES: Record<VarType, string> = { color: "Color", number: "Number", string: "String", boolean: "Boolean" };
const START: Record<VarType, unknown> = { color: "#ffffff", number: 0, string: "", boolean: true };

/** A new variable of `type` in the group shown, named after its type, ready to rename. */
export function createVariable(type: VarType): void {
  ensure();
  const c = shownCol();
  if (!c || vars.readOnly) return;
  const prefix = vars.group ? `${vars.group}/` : "";
  const own = varsOf(c);
  const name = prefix + freeName(Publr.t(TYPE_NAMES[type]), own.filter((v) => groupOf(v.name) === vars.group).map((v) => leaf(v.name)));
  const values: Record<string, unknown> = {};
  for (const m of c.modes) values[m.id] = START[type];
  const v: RawVar = { id: newId("VariableID"), name, collection: c.id, type, values };
  // After the last variable of the group (of the collection, when none).
  const inGroup = own.filter((x) => groupOf(x.name) === vars.group);
  const last = inGroup[inGroup.length - 1] ?? own[own.length - 1];
  const index = last ? list.indexOf(last) + 1 : list.length;
  vars.query = "";
  if (!apply([varChange(v, index)])) return;
  selected.clear();
  selected.add(v.id);
  anchor = v.id;
  renaming = v.id;
  rebuild();
  revealRow(v.id);
}

function revealRow(id: string): void {
  const at = flat.findIndex((e) => e.kind === "var" && e.v.id === id);
  if (at < 0 || !scroller) return;
  const top = tops[at];
  if (top < scroller.scrollTop || top + ROW > scroller.scrollTop + scroller.clientHeight - 2 * ROW) scroller.scrollTop = Math.max(0, top - scroller.clientHeight / 3);
}

/** A click on a row: selects it; Shift a range, Cmd adds or takes it away. */
export function clickVarRow(id: string, event: MouseEvent): void {
  if (suppressClick) return;
  if (event.shiftKey && anchor) {
    const ids = flat.filter((e) => e.kind === "var").map((e) => (e as { v: RawVar }).v.id);
    const a = ids.indexOf(anchor);
    const b = ids.indexOf(id);
    if (a >= 0 && b >= 0) {
      selected.clear();
      for (let k = Math.min(a, b); k <= Math.max(a, b); k++) selected.add(ids[k]);
    }
  } else if (event.metaKey || event.ctrlKey) {
    if (selected.has(id)) selected.delete(id);
    else selected.add(id);
    anchor = id;
  } else {
    selected.clear();
    selected.add(id);
    anchor = id;
  }
  drawRows();
}

/** A right-click on a row: it joins the selection unless it is in it. */
export function contextVarRow(id: string): void {
  if (!selected.has(id)) {
    selected.clear();
    selected.add(id);
    anchor = id;
    drawRows();
  }
}

export const selectedCount = () => selected.size;

export function startRenameVar(id: string): void {
  if (vars.readOnly) return;
  renaming = id;
  drawRows();
}

/** The typed name (null: Escape). A name with "/" moves the variable into that group. */
export function renameVar(id: string, name: string | null): void {
  if (renaming !== id) return;
  renaming = "";
  const v = byId.get(id);
  const clean = name?.trim() ?? "";
  if (v && name !== null && clean) {
    const g = groupOf(v.name);
    const full = g ? `${g}/${clean}` : clean;
    if (full !== v.name) apply([varChange({ ...v, name: full })]);
  }
  drawRows();
}

export function deleteSelected(): void {
  if (!selected.size || vars.readOnly) return;
  const ids = [...selected];
  selected.clear();
  apply(ids.map((id) => removeVar(id)));
}

export function duplicateSelected(): void {
  ensure();
  if (!selected.size || vars.readOnly) return;
  const picked = list.filter((v) => selected.has(v.id));
  const names = new Set(list.map((v) => v.name));
  const changes: Record<string, unknown>[] = [];
  const made: string[] = [];
  let offset = 0;
  for (const v of picked) {
    const nv: RawVar = copy(v);
    nv.id = newId("VariableID");
    delete nv.key;
    let name = `${v.name} copy`;
    for (let n = 2; names.has(name); n++) name = `${v.name} copy ${n}`;
    names.add(name);
    nv.name = name;
    offset++;
    changes.push(varChange(nv, list.indexOf(v) + offset));
    made.push(nv.id);
  }
  if (!apply(changes)) return;
  selected.clear();
  for (const id of made) selected.add(id);
}

/** The keys the window takes while it has the focus; true when it took them. */
export function varsKey(e: KeyboardEvent): boolean {
  const t = e.target as HTMLElement | null;
  if (t && (t.closest("input, textarea, select") || t.isContentEditable)) return false;
  if ((e.key === "Delete" || e.key === "Backspace") && selected.size) {
    e.preventDefault();
    deleteSelected();
    return true;
  }
  if (e.key === "Escape") {
    if (vars.edit || vars.color || vars.pick) {
      closePopovers();
      closePick();
    }
    else if (selected.size) {
      selected.clear();
      drawRows();
    } else closeVariables();
    e.preventDefault();
    return true;
  }
  if ((e.metaKey || e.ctrlKey) && e.code === "KeyA") {
    e.preventDefault();
    for (const en of flat) if (en.kind === "var") selected.add(en.v.id);
    drawRows();
    return true;
  }
  if ((e.metaKey || e.ctrlKey) && e.code === "KeyD") {
    e.preventDefault();
    duplicateSelected();
    return true;
  }
  return false;
}

// ------------------------------------------------------------ reordering rows

let suppressClick = false;

/** A press on a row: past a few pixels it drags the selected rows (or this one). */
export function rowPointerDown(id: string, event: PointerEvent): void {
  if (event.button !== 0 || renaming || vars.readOnly || vars.query) return;
  if ((event.target as HTMLElement).closest("input, button, [data-pd-cell-value]")) return;
  const y0 = event.clientY;
  let dragging = false;
  const move = (e: PointerEvent) => {
    if (!dragging) {
      if (Math.abs(e.clientY - y0) < 4) return;
      dragging = true;
      dragIds = selected.has(id) ? flat.filter((x) => x.kind === "var" && selected.has(x.v.id)).map((x) => (x as { v: RawVar }).v.id) : [id];
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
    drop();
  };
  window.addEventListener("pointermove", move, true);
  window.addEventListener("pointerup", up, true);
}

function dropOver(clientY: number): void {
  if (!scroller) return;
  const r = scroller.getBoundingClientRect();
  // The rows start under the table's header (a row high).
  const y = clientY - r.top + scroller.scrollTop - ROW;
  let at = Math.max(0, Math.min(flat.length - 1, entryAt(y)));
  const below = y - tops[at] > (tops[at + 1] - tops[at]) / 2;
  // On a group's header: above the group's first variable.
  if (flat[at]?.kind === "group") at = Math.min(flat.length - 1, at + 1);
  const e = flat[at];
  if (!e || e.kind !== "var" || dragIds.includes(e.v.id)) dropAt = null;
  else dropAt = below ? { before: "", after: e.v.id } : { before: e.v.id, after: "" };
  drawRows();
}

/** The dragged variables land above or below the row marked: in its group, in order. */
function drop(): void {
  const to = dropAt;
  const ids = dragIds;
  dragIds = [];
  dropAt = null;
  if (!to || !ids.length) {
    drawRows();
    return;
  }
  ensure();
  const target = byId.get(to.before || to.after);
  if (!target) return drawRows();
  const g = groupOf(target.name);
  const moving = ids.map((id) => byId.get(id)).filter((v): v is RawVar => !!v);
  // The list without them, then them at the target's place.
  const rest = list.filter((v) => !ids.includes(v.id));
  let at = rest.indexOf(target) + (to.after ? 1 : 0);
  const changes: Record<string, unknown>[] = [];
  for (const v of moving) {
    const name = groupOf(v.name) === g ? v.name : g ? `${g}/${leaf(v.name)}` : leaf(v.name);
    changes.push(varChange({ ...v, name }, at++));
  }
  apply(changes);
}

// ------------------------------------------------------------ values

/** Value `value` for variable `id` in mode `mode` (one step). */
function setValue(id: string, mode: string, value: unknown): void {
  const v = byId.get(id);
  if (!v || vars.readOnly) return;
  apply([varChange({ ...v, values: { ...v.values, [mode]: value } })]);
}

export function startEditCell(id: string, mode: string): void {
  if (vars.readOnly) return;
  editing = `${id}|${mode}`;
  drawRows();
}

/** A value typed in a cell (null: Escape). */
export function finishEditCell(id: string, mode: string, text: string | null): void {
  if (editing !== `${id}|${mode}`) return;
  editing = "";
  const v = byId.get(id);
  if (v && text !== null) {
    if (v.type === "number") {
      const n = Number.parseFloat(text.replace(",", "."));
      if (Number.isFinite(n)) setValue(id, mode, n);
    } else if (v.type === "string") setValue(id, mode, text);
    else if (v.type === "color") {
      const h = parseColor(text);
      if (h) setValue(id, mode, h);
    }
  }
  drawRows();
}

export function startEditAlpha(id: string, mode: string): void {
  if (vars.readOnly) return;
  editing = `${id}|${mode}|a`;
  drawRows();
}

/** A colour's opacity typed in its pill ("40", "40%"; null: Escape): the colour kept. */
export function finishEditAlpha(id: string, mode: string, text: string | null): void {
  if (editing !== `${id}|${mode}|a`) return;
  editing = "";
  const v = byId.get(id);
  const c = shownCol();
  const n = text === null ? Number.NaN : Number.parseFloat(text.replace(",", ".").replace("%", ""));
  if (v && c && Number.isFinite(n)) {
    const raw = v.values[mode] ?? v.values[c.modes[0]?.id ?? ""];
    const col = colorOf(colorPart(raw));
    setValue(id, mode, `#${col.hex.toLowerCase()}${alphaHex(Math.max(0, Math.min(100, n)) / 100)}`);
  }
  drawRows();
}

/** A typed colour ("f00", "FF0000", "#ff000080"): "#rrggbb(aa)", or null. */
function parseColor(text: string): string | null {
  let h = text.trim().replace(/^#/, "").toLowerCase();
  if (/^[0-9a-f]{3}$/.test(h)) h = h.replace(/./g, (c) => c + c);
  if (/^[0-9a-f]{1,2}$/.test(h)) h = h.padStart(2, h).repeat(3).slice(0, 6);
  return /^[0-9a-f]{6}([0-9a-f]{2})?$/.test(h) ? `#${h}` : null;
}

export function toggleBoolean(id: string, mode: string): void {
  const v = byId.get(id);
  const c = shownCol();
  if (!v || !c) return;
  const now = v.values[mode] ?? v.values[c.modes[0]?.id ?? ""];
  setValue(id, mode, now !== true);
}

/** An alias pill's detach: the value the alias gave, as the variable's own. */
export function detachAlias(id: string, mode: string): void {
  const c = shownCol();
  const v = byId.get(id);
  if (!c || !v) return;
  const k = c.modes.findIndex((m) => m.id === mode);
  const val = table[id]?.[k];
  if (val === null || val === undefined) return;
  setValue(id, mode, v.type === "color" ? `#${colorOf(colorPart(val)).hex.toLowerCase()}${alphaHex(colorOf(colorPart(val)).alpha * opacityPart(val))}` : val);
}

const alphaHex = (a: number) =>
  a >= 0.9995
    ? ""
    : Math.round(Math.max(0, Math.min(1, a)) * 255)
        .toString(16)
        .padStart(2, "0");

// ------------------------------------------------------------ the colour picker on a cell

let colorFor: { id: string; mode: string } | null = null;

export function openColor(id: string, mode: string, el: HTMLElement): void {
  if (vars.readOnly) return;
  if (vars.color && colorFor?.id === id && colorFor.mode === mode) {
    vars.color = false;
    return;
  }
  closePopovers();
  colorFor = { id, mode };
  const r = el.getBoundingClientRect();
  vars.colorLeft = Math.max(8, Math.min(window.innerWidth - 256, r.left));
  vars.colorTop = r.bottom + 4 + 330 > window.innerHeight ? Math.max(8, r.top - 334) : r.bottom + 4;
  readColor();
  vars.color = true;
}

/** The picker's colour read from its cell's variable (on opening, after an undo). */
function readColor(): void {
  if (!colorFor) return;
  const v = byId.get(colorFor.id);
  const c = shownCol();
  const raw = v?.values[colorFor.mode] ?? v?.values[c?.modes[0]?.id ?? ""];
  const col = colorOf(colorPart(raw));
  const [h, s, val] = rgbToHsv(parseInt(col.hex.slice(0, 2), 16) / 255, parseInt(col.hex.slice(2, 4), 16) / 255, parseInt(col.hex.slice(4, 6), 16) / 255);
  if (s > 0 && val > 0) vars.hue = h;
  vars.sat = s;
  vars.bright = val;
  vars.alpha = col.alpha;
  vars.hex = col.hex;
}

function writeColor(): void {
  if (!colorFor) return;
  setValue(colorFor.id, colorFor.mode, `#${vars.hex.toLowerCase()}${alphaHex(vars.alpha)}`);
}

/** A drag's colour waits for the next frame: the pointer moves faster than the document
 * follows, so a frame writes only the latest (0: none waiting). */
let colorFrame = 0;

function writeColorNow(): void {
  if (colorFrame) cancelAnimationFrame(colorFrame);
  colorFrame = 0;
  writeColor();
}

/** A pick in the square or on a slider: one step from press to release, written at most
 * once a frame; the release writes where it let go. */
export function pickColor(h: number, s: number, v: number, a: number, phase: "start" | "move" | "end"): void {
  if (phase === "start") begin();
  vars.hue = h;
  vars.sat = s;
  vars.bright = v;
  vars.alpha = a;
  vars.hex = hexOf(h, s, v).toUpperCase();
  if (phase === "start") writeColorNow();
  else if (phase === "move") colorFrame ||= requestAnimationFrame(writeColorNow);
  else {
    writeColorNow();
    commit();
  }
}

export function typedColorHex(text: string): void {
  const h = parseColor(text);
  if (!h) return;
  vars.hex = h.slice(1, 7).toUpperCase();
  const [hh, s, v] = rgbToHsv(parseInt(vars.hex.slice(0, 2), 16) / 255, parseInt(vars.hex.slice(2, 4), 16) / 255, parseInt(vars.hex.slice(4, 6), 16) / 255);
  if (s > 0 && v > 0) vars.hue = hh;
  vars.sat = s;
  vars.bright = v;
  writeColor();
}

export function typedColorAlpha(percent: number): void {
  vars.alpha = Math.max(0, Math.min(1, percent / 100));
  writeColor();
}

// ------------------------------------------------------------ the edit popover

const SCOPES: Record<VarType, { key: string; label: string; indent?: boolean }[]> = {
  color: [
    { key: "all-fills", label: "All fills" },
    { key: "frame-fill", label: "Frame", indent: true },
    { key: "shape-fill", label: "Shape", indent: true },
    { key: "text-fill", label: "Text", indent: true },
    { key: "stroke", label: "Stroke" },
    { key: "effect-color", label: "Effects" },
  ],
  number: [
    { key: "corner-radius", label: "Corner radius" },
    { key: "width-height", label: "Width and height" },
    { key: "gap", label: "Gap" },
    { key: "stroke-float", label: "Stroke" },
    { key: "opacity", label: "Layer opacity" },
    { key: "effect-float", label: "Effects" },
    { key: "font-size", label: "Font size" },
    { key: "line-height", label: "Line height" },
    { key: "letter-spacing", label: "Letter spacing" },
    { key: "paragraph-spacing", label: "Paragraph spacing" },
    { key: "paragraph-indent", label: "Paragraph indent" },
  ],
  string: [
    { key: "text-content", label: "Text content" },
    { key: "font-family", label: "Font family" },
    { key: "font-style", label: "Font style" },
  ],
  boolean: [],
};

export function openEdit(id: string, el: HTMLElement): void {
  if (vars.edit === id) {
    vars.edit = "";
    return;
  }
  closePopovers();
  const r = el.getBoundingClientRect();
  const box = el.closest("[data-pd-vars]")?.getBoundingClientRect();
  vars.editLeft = Math.min(window.innerWidth - 248, (box?.right ?? r.right) + 8);
  if (vars.editLeft + 240 > window.innerWidth - 8 || vars.full) vars.editLeft = Math.max(8, r.right - 240);
  vars.editTop = Math.max(8, Math.min(window.innerHeight - 600, r.top - 8));
  vars.editMax = window.innerHeight - vars.editTop - 8;
  vars.edit = id;
  vars.editCodeOpen = false;
  readEdit();
}

function readEdit(): void {
  const v = byId.get(vars.edit);
  if (!v) {
    vars.edit = "";
    return;
  }
  const scopes = v.scopes ?? [];
  vars.editName = leaf(v.name);
  vars.editType = v.type;
  vars.editDescription = v.description ?? "";
  vars.editAll = scopes.length === 0;
  const has = (k: string) => scopes.length === 0 || scopes.includes(k) || (k.endsWith("-fill") && k !== "all-fills" && scopes.includes("all-fills"));
  vars.editScopes = SCOPES[v.type].map((s) => ({ key: s.key, label: Publr.t(s.label), on: has(s.key), indent: !!s.indent }));
  vars.editCode = { web: v.code?.web ?? "", ios: v.code?.ios ?? "", android: v.code?.android ?? "" };
  if (vars.editCode.web || vars.editCode.ios || vars.editCode.android) vars.editCodeOpen = true;
  vars.editHidden = v.hidden === true;
}

function patchEdited(patch: Partial<RawVar>): void {
  const v = byId.get(vars.edit);
  if (!v || vars.readOnly) return;
  const next = { ...v, ...patch } as RawVar;
  for (const k of Object.keys(patch) as (keyof RawVar)[]) if (patch[k] === undefined) delete (next as Record<string, unknown>)[k];
  apply([varChange(next)]);
}

export function editName(name: string): void {
  const v = byId.get(vars.edit);
  const clean = name.trim();
  if (!v || !clean || clean === leaf(v.name)) return;
  const g = groupOf(v.name);
  patchEdited({ name: g ? `${g}/${clean}` : clean });
}

export function editDescription(text: string): void {
  const v = byId.get(vars.edit);
  if (!v || text === (v.description ?? "")) return;
  patchEdited({ description: text || undefined });
}

/** "Show in all supported properties" on (every scope) or off (none ticked yet: each one,
 * so the person takes away the ones they do not want). */
export function toggleAllScopes(): void {
  const v = byId.get(vars.edit);
  if (!v) return;
  if ((v.scopes ?? []).length === 0) patchEdited({ scopes: SCOPES[v.type].filter((s) => !s.indent).map((s) => s.key) });
  else patchEdited({ scopes: undefined });
}

export function toggleScope(key: string): void {
  const v = byId.get(vars.edit);
  if (!v) return;
  const all = SCOPES[v.type];
  const now = new Set(v.scopes?.length ? v.scopes : all.filter((s) => !s.indent).map((s) => s.key));
  // "All fills" stands for the three; one of them alone splits it.
  if (now.has("all-fills")) {
    now.delete("all-fills");
    for (const k of ["frame-fill", "shape-fill", "text-fill"]) now.add(k);
  }
  if (key === "all-fills") {
    const on = ["frame-fill", "shape-fill", "text-fill"].every((k) => now.has(k));
    for (const k of ["frame-fill", "shape-fill", "text-fill"]) {
      if (on) now.delete(k);
      else now.add(k);
    }
  } else if (now.has(key)) now.delete(key);
  else now.add(key);
  if (["frame-fill", "shape-fill", "text-fill"].every((k) => now.has(k))) {
    for (const k of ["frame-fill", "shape-fill", "text-fill"]) now.delete(k);
    now.add("all-fills");
  }
  // Pubd's empty list is "everywhere": the last scope stays ticked.
  if (now.size === 0) return;
  const full = all.filter((s) => !s.indent).every((s) => now.has(s.key));
  patchEdited({ scopes: full ? undefined : all.map((s) => s.key).filter((k) => now.has(k)) });
}

export function editCode(platform: "web" | "ios" | "android", text: string): void {
  const v = byId.get(vars.edit);
  if (!v) return;
  const code = { ...(v.code ?? {}), [platform]: text.trim() };
  for (const k of Object.keys(code) as ("web" | "ios" | "android")[]) if (!code[k]) delete code[k];
  if (JSON.stringify(code) === JSON.stringify(v.code ?? {})) return;
  patchEdited({ code: Object.keys(code).length ? code : undefined });
}

export function toggleHidden(): void {
  const v = byId.get(vars.edit);
  if (v) patchEdited({ hidden: v.hidden ? undefined : true });
}

export function closeEdit(): void {
  vars.edit = "";
}

// ------------------------------------------------------------ the variable picker

/** What a pick does: alias a value in the table, or bind a field of the selection. */
type PickFor =
  | { kind: "alias"; id: string; mode: string; type: VarType }
  | { kind: "bind"; field: BindField };

let pickFor: PickFor | null = null;

/** A field of the Design tab a variable can bind: node keys (`vars`), a text's style
 * keys, or a paint's colour. */
export type BindField = { type: VarType; scopes: string[]; keys?: string[]; also?: string[]; style?: string; paint?: PaintList; index?: number };

/** Opens the variable picker beside `el` for `what`. */
function openPick(what: PickFor, el: HTMLElement, title: string, side: "left" | "below"): void {
  ensure();
  closePopovers();
  pickFor = what;
  const r = el.getBoundingClientRect();
  if (side === "left") {
    const panel = el.closest("[data-pd-right]")?.getBoundingClientRect();
    vars.pickLeft = Math.max(8, (panel?.left ?? r.left) - 248 - 8);
    vars.pickTop = Math.max(8, Math.min(window.innerHeight - 420, r.top - 8));
  } else {
    vars.pickLeft = Math.max(8, Math.min(window.innerWidth - 256, r.left));
    vars.pickTop = r.bottom + 4 + 400 > window.innerHeight ? Math.max(8, r.top - 404) : r.bottom + 4;
  }
  vars.pickTitle = title;
  vars.pickQuery = "";
  buildPick();
  vars.pick = true;
}

export function closePick(): void {
  vars.pick = false;
  pickFor = null;
}

export function setPickQuery(q: string): void {
  vars.pickQuery = q;
  buildPick();
}

/** The variables a pick may take: of the type, offered where the field is (scopes), by
 * collection then group, the current one marked. */
function buildPick(): void {
  if (!pickFor) return;
  ensure();
  if (!defaults) {
    try {
      defaults = liveEngine()?.variableTable("") ?? {};
    } catch {
      defaults = {};
    }
  }
  const type = pickFor.kind === "alias" ? pickFor.type : pickFor.field.type;
  const scopes = pickFor.kind === "bind" ? pickFor.field.scopes : [];
  const self = pickFor.kind === "alias" ? pickFor.id : "";
  const current = pickFor.kind === "alias" ? aliasOf(pickFor.id, pickFor.mode) : boundRef(pickFor.field);
  const q = vars.pickQuery.trim().toLowerCase();
  const items: PickItem[] = [];
  // Local collections first, then those from libraries.
  const order = [...cols.filter(local), ...cols.filter((c) => c.library && !c.deleted)];
  for (const c of order) {
    const owner = c.parent ? null : c.id;
    if (!owner) continue;
    const vs = list.filter((v) => v.collection === owner && !v.deleted && v.type === type && v.id !== self && offered(v, scopes) && (!q || v.name.toLowerCase().includes(q)));
    if (!vs.length) continue;
    items.push({ key: `c:${c.id}`, head: true, id: c.id, name: c.name, path: "", type, swatch: "", value: "", current: false });
    // By group, each where its first variable is.
    const groups = new Map<string, RawVar[]>();
    for (const v of vs) {
      const g = groupOf(v.name);
      const at = groups.get(g);
      if (at) at.push(v);
      else groups.set(g, [v]);
    }
    for (const [g, gv] of groups) {
      if (g) items.push({ key: `g:${c.id}:${g}`, head: true, id: "", name: g.split("/").join(" / "), path: "group", type, swatch: "", value: "", current: false });
      for (const v of gv) {
        const val = defaults[v.id]?.[0];
        items.push({ key: v.id, head: false, id: v.id, name: leaf(v.name), path: v.name, type, swatch: type === "color" && val !== null && val !== undefined ? colorCss(val) : "", value: type === "color" ? "" : shown(type, val), current: current === v.id });
      }
    }
    if (items.length > 2000) break;
  }
  vars.pickItems = items;
}

/** Whether variable `v` is offered for a field with these scopes (none: any). */
function offered(v: RawVar, scopes: string[]): boolean {
  const own = v.scopes ?? [];
  if (!own.length || !scopes.length) return true;
  return scopes.some((s) => own.includes(s) || (s.endsWith("-fill") && own.includes("all-fills")));
}

function aliasOf(id: string, mode: string): string {
  const val = byId.get(id)?.values[mode] as { alias?: string } | undefined;
  return val && typeof val === "object" && val.alias ? val.alias : "";
}

/** The table's alias button (or an alias pill): pick the variable the value follows. */
export function openAlias(id: string, mode: string, el: HTMLElement): void {
  const v = byId.get(id);
  if (!v || vars.readOnly) return;
  openPick({ kind: "alias", id, mode, type: v.type }, el, Publr.t("Variables"), "below");
}

export function pickVariable(ref: string): void {
  const p = pickFor;
  if (!p) return;
  closePick();
  if (p.kind === "alias") setValue(p.id, p.mode, { alias: ref });
  else bindField(p.field, ref);
}

// ------------------------------------------------------------ the Design tab: bindings

/** The variable a field of the first selected layer follows ("" none). */
function boundRef(f: BindField): string {
  const info = selectedInfos()[0];
  if (!info) return "";
  const n = info.node as Record<string, unknown>;
  if (f.paint) {
    const p = panelPaints(f.paint)[f.index ?? 0];
    return typeof p?.var === "string" ? p.var : "";
  }
  if (f.style) return String(((n.style as { vars?: Record<string, string> } | undefined)?.vars ?? {})[f.style] ?? "");
  const own = (n.vars as Record<string, string> | undefined) ?? {};
  return f.keys?.length ? String(own[f.keys[0]] ?? "") : "";
}

/** The field's variable picker (the field's variable button, or Fill's styles button). */
export function openBind(field: BindField, el: HTMLElement): void {
  if (vars.pick && pickFor?.kind === "bind" && JSON.stringify(pickFor.field) === JSON.stringify(field)) {
    closePick();
    return;
  }
  openPick({ kind: "bind", field }, el, Publr.t("Variables"), "left");
}

/** Binds the field to variable `ref` on every selected layer (null: detaches it, the
 * value it had stays). */
export function bindField(f: BindField, ref: string | null): void {
  if (f.paint) {
    const list = panelPaints(f.paint);
    const p = list[f.index ?? 0];
    if (!p) return;
    if (ref) {
      const info = selectedInfos()[0];
      let val: unknown = null;
      try {
        val = liveEngine()?.variableValue(info?.node.id ?? "", ref) ?? null;
      } catch {
        val = null;
      }
      const patch: Record<string, unknown> = { type: "solid", var: ref };
      if (val !== null) {
        patch.color = `#${colorOf(colorPart(val)).hex.toLowerCase()}${alphaHex(colorOf(colorPart(val)).alpha)}`;
        if (opacityPart(val) !== 1) patch.opacity = opacityPart(val);
      }
      delete (p as Record<string, unknown>).stops;
      delete (p as Record<string, unknown>).handles;
      patchPaint(f.paint, f.index ?? 0, patch);
    } else patchPaint(f.paint, f.index ?? 0, { var: undefined });
    return;
  }
  const changes: Record<string, unknown>[] = [];
  for (const info of selectedInfos()) {
    const n = info.node as Record<string, unknown>;
    if (f.style) {
      if (n.type !== "text") continue;
      const style = { ...((n.style as Record<string, unknown> | undefined) ?? { family: "Inter" }) };
      const sv = { ...((style.vars as Record<string, string> | undefined) ?? {}) };
      if (ref) sv[f.style] = ref;
      else delete sv[f.style];
      if (Object.keys(sv).length) style.vars = sv;
      else delete style.vars;
      changes.push({ op: "set", node: info.node.id, props: { style } });
      continue;
    }
    const own = { ...((n.vars as Record<string, string> | undefined) ?? {}) };
    for (const k of f.keys ?? []) {
      if (ref) own[k] = ref;
      else delete own[k];
    }
    // The keys the field stands for besides its own (each corner of "radius").
    for (const k of f.also ?? []) delete own[k];
    changes.push({ op: "set", node: info.node.id, props: { vars: Object.keys(own).length ? own : null } });
  }
  apply(changes);
}

/** Sets (or with "" clears) the mode of collection `col` on every selected layer. */
export function setLayerMode(col: string, mode: string): void {
  const changes: Record<string, unknown>[] = [];
  for (const info of selectedInfos()) {
    const own = { ...((info.node.modes as Record<string, string> | undefined) ?? {}) };
    if (mode) own[col] = mode;
    else delete own[col];
    changes.push({ op: "set", node: info.node.id, props: { modes: Object.keys(own).length ? own : null } });
  }
  apply(changes);
}

/** The Design tab's model completed: the fields bound, the modes set. */
varHooks.inspected = (infos: NodeInfo[], insp: Inspector) => {
  const first = infos[0];
  if (!first) return;
  const n = first.node as Record<string, unknown>;
  const own = (n.vars as Record<string, string> | undefined) ?? {};
  const style = (n.style as { vars?: Record<string, string> } | undefined)?.vars ?? {};
  const modes = (n.modes as Record<string, string> | undefined) ?? {};
  const fills = ((n.fills as { var?: string }[] | undefined) ?? []).slice().reverse();
  const strokes = ((n.strokes as { var?: string }[] | undefined) ?? []).slice().reverse();
  const anyBound = Object.keys(own).length || Object.keys(style).length || fills.some((p) => p.var) || strokes.some((p) => p.var) || Object.keys(modes).length;
  if (!ensure()) return;
  vars.anyModes = cols.some((c) => c.modes.length > 1);
  if (anyBound) {
    for (const k of Object.keys(own)) insp.vars[k] = varPath(own[k]);
    // Every corner on one variable: the radius field shows it.
    const corners = [0, 1, 2, 3].map((k) => own[`radius/${k}`]);
    if (!own.radius && corners[0] && corners.every((c) => c === corners[0])) insp.vars.radius = varPath(corners[0]);
    for (const k of Object.keys(style)) insp.vars[`style/${k}`] = varPath(style[k]);
    if (!insp.fillStyle) insp.fills.forEach((row, k) => (row.variable = fills[k]?.var ? varPath(fills[k].var!) : ""));
    insp.strokes.forEach((row, k) => (row.variable = strokes[k]?.var ? varPath(strokes[k].var!) : ""));
  }
  if (!vars.anyModes) return;
  // The modes it sets, each with what Auto would give (the parent's mode).
  let inherited: { collection: string; mode: string }[] = [];
  try {
    inherited = liveEngine()?.nodeModes(first.parent?.id ?? "") ?? [];
  } catch {
    inherited = [];
  }
  for (const cid of Object.keys(modes)) {
    const c = colById.get(cid);
    if (!c) continue;
    const auto = inherited.find((x) => x.collection === cid)?.mode ?? c.modes[0]?.id;
    const autoName = c.modes.find((m) => m.id === auto)?.name ?? "";
    insp.modeRows.push({
      collection: cid,
      name: c.name,
      mode: c.modes.find((m) => m.id === modes[cid])?.name ?? modes[cid],
      options: [{ value: "", label: `${Publr.t("Auto")} (${autoName})` }, ...c.modes.map((m) => ({ value: m.id, label: m.name }))],
    });
  }
  // Local collections, and those from libraries the file has none of its own like.
  const localNames = new Set(cols.filter(local).map((c) => c.name));
  insp.modeMenu = cols.filter((c) => c.modes.length > 1 && !(c.id in modes) && !c.parent && (local(c) || !localNames.has(c.name))).map((c) => ({ collection: c.id, name: c.name, modes: c.modes.map((m) => ({ id: m.id, name: m.name })) }));
};

// The pickers follow the selection.
let lastSelection = "";
Publr.effect(() => {
  const now = shell.selection.join(",");
  if (now !== lastSelection) {
    lastSelection = now;
    Publr.untrack(() => {
      if (pickFor?.kind === "bind") closePick();
    });
  }
});

/** The table's column widths: a divider dragged. */
export function resizeColumn(which: "name" | "mode", event: PointerEvent): void {
  event.preventDefault();
  event.stopPropagation();
  const x0 = event.clientX;
  const w0 = which === "name" ? vars.nameW : vars.modeW;
  const move = (e: PointerEvent) => {
    const w = Math.max(120, Math.min(600, Math.round(w0 + e.clientX - x0)));
    if (which === "name") vars.nameW = w;
    else vars.modeW = w;
  };
  const up = () => {
    window.removeEventListener("pointermove", move, true);
    window.removeEventListener("pointerup", up, true);
  };
  window.addEventListener("pointermove", move, true);
  window.addEventListener("pointerup", up, true);
}

/** The window dragged by its header, or resized by its corner. */
export function windowDrag(how: "move" | "size", event: PointerEvent): void {
  if (event.button !== 0 || vars.full) return;
  if (how === "move" && (event.target as HTMLElement).closest("button, input")) return;
  event.preventDefault();
  const x0 = event.clientX;
  const y0 = event.clientY;
  const a = { x: vars.x, y: vars.y, w: vars.winW, h: vars.winH };
  const move = (e: PointerEvent) => {
    const dx = e.clientX - x0;
    const dy = e.clientY - y0;
    if (how === "move") {
      vars.x = Math.max(-a.w + 120, Math.min(window.innerWidth - 120, a.x + dx));
      vars.y = Math.max(0, Math.min(window.innerHeight - 48, a.y + dy));
    } else {
      vars.winW = Math.max(560, a.w + dx);
      vars.winH = Math.max(320, a.h + dy);
    }
  };
  const up = () => {
    window.removeEventListener("pointermove", move, true);
    window.removeEventListener("pointerup", up, true);
  };
  window.addEventListener("pointermove", move, true);
  window.addEventListener("pointerup", up, true);
}

export function setQuery(q: string): void {
  vars.query = q;
  if (scroller) scroller.scrollTop = 0;
  viewTop = 0;
  rebuild();
}

export function toggleSearch(): void {
  vars.searching = !vars.searching;
  if (!vars.searching && vars.query) setQuery("");
}
