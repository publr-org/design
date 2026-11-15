// Sampling: taking values from the free canvas beside into the design system. A
// selection's colours, text styles, icons, radii, spacing, shadows or a component, read
// from the layers as the engine holds them, folded together (the same value, or a
// colour within ΔE00 2) and against what the system has, shown in a short preview, then
// added as one change. A layer dragged across onto the design system canvas adds what
// the section under the pointer takes, at once.
//
// Glue, not UI: SampleDialog.ptsx renders `sample`.

import { Publr } from "publr-jsx";
import { toast } from "../app/route";
import { canvasTools, shell, targetAt } from "../design/store";
import type { Outside } from "../design/tools/canvas";
import { viewerEditing } from "../viewer/Viewer.ptsx";
import { addIcons, iconNameFrom } from "../../../editor/design/model/icons";
import { cssLengthPx, fontRoles } from "../../../editor/design/model/system";
import { scaleValue } from "../../../editor/design/model/typescale";
import { cssColor, deltaE, pubdColor, toHex } from "./color";
import type { Rgba } from "./color";
import { svgFromPubd } from "./icons";
import { addBreakpoint, addEntry, addFont, addScaleToken, entryFamily, familyOf, fonts, resolveValue, scaleTokens, setRoleColor, styleBreakpoints, tokenLabel } from "./model";
import type { Doc, DesignSystem, ItemRef, SectionKey, TypeScaleEntry } from "./model";
import { change, currentDoc, dsCanvas, sys } from "./store";

type N = Record<string, unknown>;

export type SampleKind = "colors" | "type" | "icons" | "radii" | "spacing" | "shadows" | "primitive";

export const SAMPLE_LABELS: Record<SampleKind, string> = {
  colors: Publr.t("Add colours as tokens"),
  type: Publr.t("Add to type scale"),
  icons: Publr.t("Add icons"),
  radii: Publr.t("Add radii"),
  spacing: Publr.t("Add spacing"),
  shadows: Publr.t("Add shadows"),
  primitive: Publr.t("Set as primitive default"),
};

/** One row of the preview: a value found, and whether it is added. */
export type Row = {
  key: string;
  label: string;
  detail: string;
  /** A colour to show beside it ("" none). */
  swatch: string;
  /** Uses in the selection. */
  count: number;
  /** "new": added when ticked; "exists": the system has it (or one within ΔE00 2). */
  status: "new" | "exists";
  include: boolean;
  /** What is added: a token value, a type entry, an icon. */
  value: unknown;
};

export const sample = Publr.reactive({
  open: false,
  kind: "colors" as SampleKind,
  title: "",
  rows: [] as Row[],
  /** Primitive: the block the component becomes the default of. */
  block: "",
  componentName: "",
  note: "",
});

// ------------------------------------------------------------ reading the selection

function subtree(id: string): N | null {
  const e = viewerEditing()?.engine;
  if (!e) return null;
  try {
    return e.canvasSubtree(id) as N;
  } catch {
    return null;
  }
}

function walk(n: N, fn: (n: N) => void): void {
  if (n.visible === false) return;
  fn(n);
  for (const c of (n.children as N[]) ?? []) walk(c, fn);
}

function solids(paints: unknown): (Rgba & { variable?: string })[] {
  const out: (Rgba & { variable?: string })[] = [];
  for (const p of (paints as N[]) ?? []) {
    if (p.visible === false || p.type !== "solid") continue;
    const c = pubdColor(p.color);
    if (c) out.push({ ...c, a: c.a * (typeof p.opacity === "number" ? p.opacity : 1), variable: typeof p.var === "string" ? p.var : undefined });
  }
  return out;
}

/** The names of the file's variables by id ("Colors/Gray (light mode)/50"), read once
 * per sampling. A value bound to a variable is named after it. */
function variableNames(): Map<string, string> {
  const names = new Map<string, string>();
  try {
    for (const v of viewerEditing()?.engine?.variables().variables ?? []) names.set(v.id, v.name);
  } catch {
    // An engine without variables.
  }
  return names;
}

/** A variable's name as a token label: its groups after the first, spaced. */
const variableLabel = (name: string) => {
  const parts = name.split("/").filter(Boolean);
  return (parts.length > 1 ? parts.slice(1) : parts).join(" ");
};

/** A layer's name, when it says something of its own (not "Rectangle 12", not a hex). */
function ownName(n: N): string {
  const name = String(n.name ?? "").trim();
  if (!name || /^(rectangle|ellipse|frame|group|vector|line|polygon|star|text|component|instance)\b/i.test(name) || /^#?[\da-f]{6}$/i.test(name) || name === n.text) return "";
  return name;
}

type Found<T> = Map<string, { value: T; count: number; label: string }>;

function tally<T>(found: Found<T>, key: string, value: T, label: string): void {
  const f = found.get(key);
  if (f) {
    f.count++;
    f.label ||= label;
  }
  else found.set(key, { value, count: 1, label });
}

/** Colours: the layers' fills and strokes (and their children's); the text's colours
 * only when the shapes have none (a swatch's labels are not its colour). */
function readColors(ids: string[]): Found<Rgba> {
  const shapes: Found<Rgba> = new Map();
  const texts: Found<Rgba> = new Map();
  const vars = variableNames();
  for (const id of ids) {
    const n = subtree(id);
    if (!n) continue;
    walk(n, (x) => {
      const into = x.type === "text" ? texts : shapes;
      for (const c of [...solids(x.fills), ...solids(x.strokes)]) {
        if (c.a <= 0.01) continue;
        const named = c.variable ? vars.get(c.variable) : undefined;
        const { variable: _v, ...rgba } = c;
        tally(into, toHex(rgba), rgba, named ? variableLabel(named) : ownName(x));
      }
    });
  }
  return shapes.size ? shapes : texts;
}

type Style = { family: string; weight: number; fontStyle: string; size: number; lh: number | null; ls: number; case: string };

function styleOf(n: N): Style | null {
  const s = n.style as N | undefined;
  if (!s || typeof s.family !== "string") return null;
  const size = Number(s.size ?? 16);
  const lhv = s.lineHeight as N | string | undefined;
  const lh = lhv && typeof lhv === "object" ? (typeof lhv.px === "number" ? lhv.px : typeof lhv.percent === "number" ? (size * lhv.percent) / 100 : null) : null;
  const lsv = s.letterSpacing as N | number | undefined;
  const ls = typeof lsv === "number" ? lsv : lsv && typeof lsv === "object" && typeof lsv.percent === "number" ? (size * lsv.percent) / 100 : 0;
  return { family: s.family, weight: Number(s.weight ?? 400), fontStyle: String(s.fontStyle ?? ""), size, lh, ls, case: String(s.case ?? "none") };
}

function readType(ids: string[]): Found<Style> {
  const found: Found<Style> = new Map();
  for (const id of ids) {
    const n = subtree(id);
    if (!n) continue;
    walk(n, (x) => {
      if (x.type !== "text") return;
      const s = styleOf(x);
      if (s) tally(found, `${s.family}|${s.weight}|${s.size}|${s.lh}|${Math.round(s.ls * 100)}|${s.case}`, s, ownName(x));
    });
  }
  return found;
}

function readNumbers(ids: string[], pick: (n: N) => number[]): Found<number> {
  const found: Found<number> = new Map();
  for (const id of ids) {
    const n = subtree(id);
    if (!n) continue;
    walk(n, (x) => {
      for (const v of pick(x)) if (v > 0 && Number.isFinite(v)) tally(found, String(Math.round(v * 100) / 100), Math.round(v * 100) / 100, "");
    });
  }
  return found;
}

const radiiOf = (n: N): number[] => (typeof n.radius === "number" ? [n.radius] : Array.isArray(n.radius) ? (n.radius as number[]) : []);

function spacingOf(n: N): number[] {
  const l = n.layout as N | undefined;
  if (!l) return [];
  return [Number(l.gap ?? 0), ...(((l.padding as number[]) ?? []) as number[])];
}

function readShadows(ids: string[]): Found<string> {
  const found: Found<string> = new Map();
  for (const id of ids) {
    const n = subtree(id);
    if (!n) continue;
    walk(n, (x) => {
      for (const e of (x.effects as N[]) ?? []) {
        if (e.visible === false || (e.type !== "drop-shadow" && e.type !== "inner-shadow")) continue;
        const o = (e.offset as number[]) ?? [0, 0];
        const c = pubdColor(e.color) ?? { r: 0, g: 0, b: 0, a: 0.25 };
        const css = `${e.type === "inner-shadow" ? "inset " : ""}${o[0]}px ${o[1]}px ${Number(e.radius ?? 0)}px ${Number(e.spread ?? 0)}px ${toHex(c)}`;
        tally(found, css, css, ownName(x));
      }
    });
  }
  return found;
}

// ------------------------------------------------------------ folding

const pxOf = (v: string) => cssLengthPx(v.trim());

/** Colours: folded with each other (ΔE00 2, the most used kept) and against the palette. */
function colorRows(s: DesignSystem, found: Found<Rgba>): Row[] {
  const list = [...found.values()].sort((a, b) => b.count - a.count);
  const kept: { value: Rgba; count: number; label: string; also: string[] }[] = [];
  for (const f of list) {
    const k = f.value.a > 0.999 ? kept.find((x) => x.value.a > 0.999 && deltaE(x.value, f.value) <= 2) : kept.find((x) => toHex(x.value) === toHex(f.value));
    if (k) {
      k.count += f.count;
      k.also.push(toHex(f.value));
      k.label ||= f.label;
    } else kept.push({ ...f, also: [] });
  }
  const palette = scaleTokens(s, "color").map((t) => ({ name: t.name, c: cssColor(resolveValue(s, t.value)) }));
  return kept.map((k) => {
    const hex = toHex(k.value);
    const near = palette.filter((p) => p.c && (k.value.a > 0.999 ? deltaE(p.c, k.value) <= 2 : toHex(p.c) === hex)).sort((a, b) => deltaE(a.c!, k.value) - deltaE(b.c!, k.value))[0];
    const folded = k.also.length ? ` · ${k.also.join(", ")} folded in` : "";
    return {
      key: hex,
      label: k.label || hex.toUpperCase(),
      detail: near ? `${Publr.t("In the system as")} ${tokenLabel(near.name)}${deltaE(near.c!, k.value) >= 0.05 ? ` (ΔE ${deltaE(near.c!, k.value).toFixed(1)})` : ""}${folded}` : `${hex.toUpperCase()} · ${k.count}×${folded}`,
      swatch: hex,
      count: k.count,
      status: near ? "exists" : "new",
      include: !near,
      value: { hex, label: k.label },
    };
  });
}

/** The font role (or family) key a family is set through, made when the system lacks it. */
function roleFor(s: DesignSystem, family: string): { system: DesignSystem; role: string } {
  const role = fontRoles(s).find((r) => familyOf(s, r.token) === family);
  if (role) return { system: s, role: role.key };
  const fam = fonts(s).find((t) => familyOf(s, t.name) === family);
  if (fam) return { system: s, role: fam.name.slice("font-".length) };
  const added = addFont(s, family, /serif|works|garamond|times|georgia/i.test(family) ? "serif" : "sans-serif");
  if (typeof added === "string") return { system: s, role: "body" };
  return { system: added.system, role: added.token.slice("font-".length) };
}

function sameEntry(s: DesignSystem, e: TypeScaleEntry, st: Style): boolean {
  const size = pxOf(scaleValue(s, e.size, "text-")) ?? 16;
  const lhText = scaleValue(s, e.lineHeight, "leading-");
  const lh = lhText ? pxOf(lhText) : null;
  return entryFamily(s, e) === st.family && e.weight === st.weight && Math.abs(size - st.size) < 0.5 && ((lh === null && st.lh === null) || (lh !== null && st.lh !== null && Math.abs(lh - st.lh) < 0.5));
}

function typeRows(s: DesignSystem, found: Found<Style>): Row[] {
  return [...found.values()]
    .sort((a, b) => b.count - a.count)
    .map((f) => {
      const st = f.value;
      const spec = `${st.family} ${st.weight} · ${st.size}/${st.lh === null ? "auto" : Math.round(st.lh * 10) / 10}${st.ls ? ` · ${Math.round(st.ls * 100) / 100}` : ""}`;
      const have = s.typeScale.find((e) => sameEntry(s, e, st));
      return { key: spec, label: f.label || spec, detail: have ? `${Publr.t("In the system as")} ${have.label}` : `${spec} · ${f.count}×${sys.faces[st.family] ? "" : ` · ${Publr.t("font not here")}`}`, swatch: "", count: f.count, status: have ? "exists" : "new", include: !have, value: st } as Row;
    });
}

function numberRows(s: DesignSystem, kind: "radius" | "spacing", found: Found<number>): Row[] {
  const have = scaleTokens(s, kind).map((t) => ({ name: t.name, v: pxOf(resolveValue(s, t.value)) }));
  return [...found.values()]
    .sort((a, b) => a.value - b.value)
    .map((f) => {
      const near = have.find((h) => h.v !== null && Math.abs(h.v - f.value) < 0.5);
      return { key: String(f.value), label: `${f.value}px`, detail: near ? `${Publr.t("In the system as")} ${tokenLabel(near.name)}` : `${f.count}×`, swatch: "", count: f.count, status: near ? "exists" : "new", include: !near, value: f.value } as Row;
    });
}

function shadowRows(s: DesignSystem, found: Found<string>): Row[] {
  const have = scaleTokens(s, "shadow").map((t) => ({ name: t.name, v: resolveValue(s, t.value).replace(/\s+/g, " ").trim().toLowerCase() }));
  return [...found.values()].map((f) => {
    const near = have.find((h) => h.v === f.value.toLowerCase());
    return { key: f.value, label: f.label || f.value, detail: near ? `${Publr.t("In the system as")} ${tokenLabel(near.name)}` : `${f.value} · ${f.count}×`, swatch: "", count: f.count, status: near ? "exists" : "new", include: !near, value: f.value } as Row;
  });
}

function iconRows(s: DesignSystem, ids: string[]): Row[] {
  const rows: Row[] = [];
  for (const id of ids) {
    const n = subtree(id);
    if (!n) continue;
    const name = iconNameFrom(String(n.name ?? "icon")) || "icon";
    const have = s.icons.find((i) => i.name === name);
    rows.push({ key: `${name}:${id}`, label: name, detail: have ? Publr.t("Replaces the icon of that name") : `${Math.round(((n.size as number[]) ?? [0])[0])} × ${Math.round(((n.size as number[]) ?? [0, 0])[1])}`, swatch: "", count: 1, status: "new", include: true, value: { name, svg: svgFromPubd(n) } });
  }
  return rows;
}

/** The block a component's name suggests ("Primary Button" → button). */
function guessBlock(name: string): string {
  const lower = name.toLowerCase();
  const hit = sys.blocks.find((b) => lower.includes(b.type) || lower.includes(b.label.toLowerCase()));
  return hit?.type ?? sys.blocks.find((b) => b.type === "button")?.type ?? sys.blocks[0]?.type ?? "";
}

// ------------------------------------------------------------ the preview and adding

/** Opens the preview for the free side's selection. */
export function openSample(kind: SampleKind, ids = shell.selection): void {
  const doc = currentDoc();
  if (!doc || !ids.length) return;
  const s = doc.system;
  sample.kind = kind;
  sample.title = SAMPLE_LABELS[kind];
  sample.note = "";
  sample.block = "";
  sample.componentName = "";
  if (kind === "colors") sample.rows = colorRows(s, readColors(ids));
  else if (kind === "type") sample.rows = typeRows(s, readType(ids));
  else if (kind === "radii") sample.rows = numberRows(s, "radius", readNumbers(ids, radiiOf));
  else if (kind === "spacing") sample.rows = numberRows(s, "spacing", readNumbers(ids, spacingOf));
  else if (kind === "shadows") sample.rows = shadowRows(s, readShadows(ids));
  else if (kind === "icons") sample.rows = iconRows(s, ids);
  else {
    const n = subtree(ids[0]);
    if (!n) return;
    sample.componentName = String(n.name ?? "Component");
    sample.block = guessBlock(sample.componentName);
    sample.rows = [{ key: ids[0], label: sample.componentName, detail: String(n.type), swatch: "", count: 1, status: "new", include: true, value: n }];
  }
  if (!sample.rows.length) sample.note = Publr.t("The selection has nothing of this kind.");
  sample.open = true;
}

/** What the reference's selection holds to sample, for the right panel: per kind, how
 * many values were found and how many the system lacks. */
export function summarize(ids: string[]): { count: number; rows: { kind: SampleKind; label: string; detail: string; found: number; fresh: number }[] } {
  const doc = currentDoc();
  if (!doc || !ids.length) return { count: ids.length, rows: [] };
  const s = doc.system;
  const out: { kind: SampleKind; label: string; detail: string; found: number; fresh: number }[] = [];
  const add = (kind: SampleKind, rows: Row[], one: string, many: string, label: string) => {
    if (!rows.length) return;
    out.push({ kind, label, detail: `${rows.length} ${rows.length === 1 ? one : many}`, found: rows.length, fresh: rows.filter((r) => r.status === "new").length });
  };
  try {
    add("colors", colorRows(s, readColors(ids)), Publr.t("colour"), Publr.t("colours"), Publr.t("Add as tokens"));
    add("type", typeRows(s, readType(ids)), Publr.t("text style"), Publr.t("text styles"), Publr.t("Add to type scale"));
    add("radii", numberRows(s, "radius", readNumbers(ids, radiiOf)), Publr.t("radius"), Publr.t("radii"), Publr.t("Add radii"));
    add("spacing", numberRows(s, "spacing", readNumbers(ids, spacingOf)), Publr.t("spacing value"), Publr.t("spacing values"), Publr.t("Add spacing"));
    add("shadows", shadowRows(s, readShadows(ids)), Publr.t("shadow"), Publr.t("shadows"), Publr.t("Add shadows"));
  } catch (err) {
    console.error("design system: the selection could not be read", err);
  }
  return { count: ids.length, rows: out };
}

export function toggleRow(key: string): void {
  sample.rows = sample.rows.map((r) => (r.key === key && r.status === "new" ? { ...r, include: !r.include } : r));
}

export function closeSample(): void {
  sample.open = false;
}

/** The next document with `rows` added (and the item to select). */
function added(doc: Doc, kind: SampleKind, rows: Row[], block: string): { doc: Doc; select: ItemRef | null } {
  let s = doc.system;
  let select: ItemRef | null = null;
  if (kind === "colors")
    for (const r of rows) {
      const v = r.value as { hex: string; label: string };
      const x = addScaleToken(s, "color", v.label || v.hex.slice(1), v.hex);
      s = x.system;
      select = { kind: "color", key: x.name };
    }
  else if (kind === "type")
    for (const r of rows) {
      const st = r.value as Style;
      const role = roleFor(s, st.family);
      s = role.system;
      const tcase = st.case === "upper" ? "uppercase" : st.case === "lower" ? "lowercase" : st.case === "title" ? "capitalize" : "";
      const x = addEntry(s, r.label, { fontRole: role.role, weight: st.weight, size: `${st.size}px`, lineHeight: st.lh === null ? "" : `${Math.round(st.lh * 100) / 100}px`, letterSpacing: `${Math.round(st.ls * 100) / 100}px`, textTransform: tcase, description: Publr.t("Sampled from the canvas.") });
      s = x.system;
      if (x.key) select = { kind: "type", key: x.key };
    }
  else if (kind === "radii" || kind === "spacing")
    for (const r of rows) {
      const k = kind === "radii" ? "radius" : "spacing";
      const x = addScaleToken(s, k, String(r.value), `${r.value}px`);
      s = x.system;
      select = { kind: k, key: x.name };
    }
  else if (kind === "shadows")
    for (const r of rows) {
      const x = addScaleToken(s, "shadow", r.label === r.value ? "sampled" : r.label, String(r.value));
      s = x.system;
      select = { kind: "shadow", key: x.name };
    }
  else if (kind === "icons") {
    const r = addIcons(
      s,
      rows.map((x) => ({ ...(x.value as { name: string; svg: string }), category: "Sampled" })),
    );
    if (!r.error) s = r.system;
    const last = rows[rows.length - 1]?.value as { name: string } | undefined;
    if (last) select = { kind: "icon", key: last.name };
  } else if (kind === "primitive" && block && rows[0]) {
    return { doc: { ...doc, system: s, primitives: { ...doc.primitives, [block]: { name: rows[0].label, node: rows[0].value as N } } }, select: { kind: "block", key: block } };
  }
  return { doc: { ...doc, system: s }, select };
}

/** Adds the ticked rows: one change, one undo step on the design system. */
export function applySample(): void {
  const doc = currentDoc();
  if (!doc) return;
  const rows = sample.rows.filter((r) => r.status === "new" && r.include);
  sample.open = false;
  if (!rows.length) return;
  const r = added(doc, sample.kind, rows, sample.block);
  change(r.doc, r.select);
  toast(`${Publr.t("Added to the design system")}: ${rows.length}`, 2500);
}

// ------------------------------------------------------------ dragging across

/** What a layer dropped on a section adds. */
function dropKind(section: SectionKey, n: N): SampleKind | "breakpoint" | "role" {
  if (section === "typescale" || section === "typography" || section === "fonts") return "type";
  if (section === "icons") return "icons";
  if (section === "blocks") return "primitive";
  if (section === "breakpoints") return "breakpoint";
  if (section === "semantic") return "role";
  if (section === "tokens") return n.type === "text" && !solids(n.fills).length ? "type" : "colors";
  return n.type === "text" ? "type" : n.type === "component" || n.type === "instance" ? "primitive" : "colors";
}

const KIND_TEXT: Record<string, string> = { colors: "Add as colour token", type: "Add to type scale", icons: "Add as icon", primitive: "Set as primitive default", breakpoint: "Add as breakpoint (its width)", role: "Point the role at this colour" };

/** What a drag carries: the selection when it is a component (a default), else the
 * deepest layer where the drag was pressed (the swatch, the text), when the selection
 * holds it. */
function carriedIds(ids: string[], from: [number, number]): string[] {
  const n = subtree(ids[0]);
  if (!n || n.type === "component" || n.type === "instance" || ids.length > 1) return ids;
  const deep = targetAt(from[0], from[1], true);
  if (!deep || deep === ids[0]) return ids;
  let inside = false;
  walk(n, (x) => (inside ||= x.id === deep));
  if (!inside) return ids;
  // The deepest layer's frame when it is a labelled unit (a swatch with its name): its
  // own shape first, else itself.
  return [deep];
}

/** The pill a carried layer shows over the design system. */
function hint(all: string[], e: PointerEvent, from: [number, number]): void {
  const ids = carriedIds(all, from);
  const c = dsCanvas();
  const at = c?.dropAt(e.clientX, e.clientY) ?? null;
  const n = subtree(ids[0]);
  if (!at || !n) {
    sys.ghost = { show: true, x: e.clientX, y: e.clientY, text: Publr.t("Drop on a section of the design system"), swatch: "", ok: false };
    return;
  }
  const kind = dropKind(at.section, n);
  const color = readColors([ids[0]]);
  const first = [...color.values()].sort((a, b) => b.count - a.count)[0];
  const blockText = kind === "primitive" && at.item?.kind === "block" ? ` · ${sys.blocks.find((b) => b.type === at.item!.key)?.label ?? at.item.key}` : "";
  const roleText = kind === "role" && at.item?.kind === "role" ? ` · ${at.item.key}` : "";
  sys.ghost = { show: true, x: e.clientX, y: e.clientY, text: `${KIND_TEXT[kind]}${blockText}${roleText}`, swatch: kind === "colors" || kind === "role" ? (first ? toHex(first.value) : "") : "", ok: kind !== "role" || at.item?.kind === "role" };
}

/** A layer let go over the design system: what the section takes is added at once
 * (a component with no block under it asks which block). */
function dropped(all: string[], e: PointerEvent, from: [number, number]): void {
  let ids = carriedIds(all, from);
  const c = dsCanvas();
  const at = c?.dropAt(e.clientX, e.clientY) ?? null;
  c?.clearDrop();
  sys.ghost = { ...sys.ghost, show: false };
  const doc = currentDoc();
  const n = subtree(ids[0]);
  if (!at || !doc || !n) return;
  sys.focus = "system";
  const kind = dropKind(at.section, n);
  const s = doc.system;
  // A frame, an icon or a component goes as selected; a colour or a text from the
  // layer the drag was pressed on.
  if (kind === "breakpoint" || kind === "primitive" || kind === "icons") ids = all;
  const whole = subtree(ids[0]) ?? n;
  if (kind === "breakpoint") {
    const w = Math.round(((whole.size as number[]) ?? [0])[0]);
    if (styleBreakpoints(s).some((b) => (cssLengthPx(b.viewport) ?? 0) === w)) return toast(`${w}px ${Publr.t("is a breakpoint already")}`, 2500);
    let k = 1;
    while (styleBreakpoints(s).some((b) => b.key === `bp-${w}${k > 1 ? `-${k}` : ""}`)) k++;
    const key = `bp-${w}${k > 1 ? `-${k}` : ""}`;
    const r = addBreakpoint(s, key, String(w), w < 768 ? "mobile" : w < 1024 ? "tablet" : "desktop");
    if (!r.error) change({ ...doc, system: r.system }, { kind: "breakpoint", key });
    return;
  }
  if (kind === "role") {
    if (at.item?.kind !== "role") return;
    const rows = colorRows(s, readColors([ids[0]]));
    const row = rows.sort((a, b) => b.count - a.count)[0];
    if (!row) return;
    // The role points at the palette colour (a new one when the palette lacks it).
    let next = s;
    let token = scaleTokens(s, "color").find((t) => {
      const c = cssColor(resolveValue(s, t.value));
      const v = cssColor(row.swatch);
      return c && v && deltaE(c, v) <= 2;
    })?.name;
    if (!token) {
      const x = addScaleToken(s, "color", (row.value as { label: string }).label || row.swatch.slice(1), row.swatch);
      next = x.system;
      token = x.name;
    }
    change({ ...doc, system: setRoleColor(next, at.item.key, `var(--${token})`) }, at.item);
    return;
  }
  if (kind === "primitive") {
    if (at.item?.kind === "block") {
      change({ ...doc, primitives: { ...doc.primitives, [at.item.key]: { name: String(whole.name ?? "Component"), node: whole } } }, at.item);
      return;
    }
    openSample("primitive", ids);
    return;
  }
  const rows =
    kind === "colors"
      ? colorRows(s, readColors([ids[0]])).sort((a, b) => b.count - a.count).slice(0, 1)
      : kind === "type"
        ? typeRows(s, readType([ids[0]])).slice(0, 1)
        : iconRows(s, ids);
  const fresh = rows.filter((r) => r.status === "new");
  if (!fresh.length) {
    const r = rows[0];
    toast(r ? `${r.label}: ${r.detail}` : Publr.t("Nothing there this section takes."), 3000);
    return;
  }
  const r = added(doc, kind, fresh, "");
  change(r.doc, r.select);
}

/** The free canvas's drags carried across onto the design system canvas. */
export function installCarry(): void {
  const tools = canvasTools();
  if (!tools) {
    requestAnimationFrame(installCarry);
    return;
  }
  const outside: Outside = {
    over: (e) => !!dsCanvas()?.over(e.clientX, e.clientY),
    move: (e, ids, from) => hint(ids, e, from),
    drop: (e, ids, from) => dropped(ids, e, from),
    leave: () => {
      sys.ghost = { ...sys.ghost, show: false };
      dsCanvas()?.clearDrop();
    },
  };
  tools.outside = outside;
}

export function uninstallCarry(): void {
  const tools = canvasTools();
  if (tools) tools.outside = null;
}
