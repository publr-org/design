// The design system canvas as a Pubd scene, drawn from the data: one column per layer of
// the builder (Library, Semantic layer, Defaults, System), a white card per section in
// the builder's order, each item a frame of its own laid out by the engine's auto
// layout (as Bring in's `build` lays out its "Design system" page). Ids are made from
// the items (`sys:color:color-palette-navy`), so the same data always gives the same
// scene, and `diff` turns one scene into the next with the few changes the engine
// applies in one step: an edit redraws only what it changed, and undo puts both the
// data (kept on the page) and the scene back.
//
// Glue, not UI.

import { breakpointRange, styleBreakpoints } from "../../../editor/design/model/breakpoints";
import { containers } from "../../../editor/design/model/containers";
import { Publr } from "publr-jsx";
import { colorContexts, cssLengthPx, fontRoles, resolveValue, roleToken, semanticRoles, tokenValue } from "../../../editor/design/model/system";
import { scaleValue } from "../../../editor/design/model/typescale";
import { cssColor, luminance, toHex } from "./color";
import { pubdFromSvg } from "./icons";
import { breakpointDevice, entryFamily, familyOf, fontLabel, fonts, GROUPS, roleColor, rolePalette, scaleTokens, tokenLabel } from "./model";
import type { Doc, ItemKind, ItemRef, SectionKey } from "./model";

/** A scene node: Pubd node JSON, plus `__fixed` (its size is the data's, not layout's). */
export type SNode = { id: string; type: string; children?: SNode[]; __fixed?: boolean; [key: string]: unknown };

/** What a scene is built with besides the data. */
export type SceneContext = {
  /** The face name of `family` at `weight` here ("" when the family is missing). */
  face(family: string, weight: number): string;
  /** The weights `family` has here. */
  weights(family: string): number[];
  /** The blocks an author can insert (type, label, category), in the inserter's order. */
  blocks: { type: string; label: string; category: string }[];
  /** The text type specimens show. */
  sample: string;
  /** The system's name ("Caraway"). */
  name: string;
};

/** The scene and what its nodes are. */
export type Scene = {
  roots: SNode[];
  /** Item roots by node id. */
  items: Map<string, ItemRef>;
  /** Section cards by node id. */
  sections: Map<string, SectionKey>;
  /** The "+ Add" chips by node id: the kind they add. */
  chips: Map<string, ItemKind>;
};

export const PAGE_ID = "sys:page";
export const COLUMN_WIDTH = 1212;
const COLUMN_GAP = 240;
const INNER = 1100;
const CHROME = "Inter";
const INK = "#1a1a1c";
const MUTED = "#737378";
const LINE = "#e1e1e6";
const SOFT = "#f4f4f6";
const BAR = "#c9c9d1";

export const itemId = (r: ItemRef) => `sys:${r.kind}:${r.key}`;
export const sectionId = (k: SectionKey) => `sys:section:${k}`;

const solid = (hex: string) => [{ type: "solid", color: hex }];

class Builder {
  ctx: SceneContext;
  items = new Map<string, ItemRef>();
  sections = new Map<string, SectionKey>();
  chips = new Map<string, ItemKind>();

  constructor(ctx: SceneContext) {
    this.ctx = ctx;
  }

  frame(id: string, name: string, mode: "horizontal" | "vertical", gap: number, pad: number | number[], children: SNode[], extra: Record<string, unknown> = {}): SNode {
    const padding = Array.isArray(pad) ? pad : [pad, pad, pad, pad];
    const { layout, ...rest } = extra as { layout?: Record<string, unknown> };
    return { id, type: "frame", name, size: [10, 10], layout: { mode, gap, padding, width: "hug", height: "hug", ...(layout ?? {}) }, children, ...rest };
  }

  /** A row `width` wide that wraps. */
  wrap(id: string, name: string, width: number, gap: number, children: SNode[]): SNode {
    return { id, type: "frame", name, size: [width, 10], __fixed: true, layout: { mode: "horizontal", wrap: true, gap, crossGap: gap, padding: [0, 0, 0, 0], width: "fixed", height: "hug" }, children };
  }

  text(id: string, s: string, size: number, lh: number | null, color: string, opts: { family?: string; weight?: number; width?: number; style?: string; extra?: Record<string, unknown> } = {}): SNode {
    const family = opts.family ?? CHROME;
    const weight = opts.weight ?? 400;
    const fontStyle = opts.style || this.ctx.face(family, weight) || faceName(weight);
    const n: SNode = {
      id,
      type: "text",
      name: s.slice(0, 40) || "text",
      fills: solid(color),
      size: [opts.width ?? 10, lh ?? size],
      text: s,
      style: { family, weight, fontStyle, size, lineHeight: lh === null ? "auto" : { px: lh }, ...(opts.extra ?? {}) },
      resize: opts.width ? "height" : "width-and-height",
    };
    if (opts.width) n.__fixed = true;
    return n;
  }

  strong(id: string, s: string, width?: number): SNode {
    return this.text(id, s, 14, 20, INK, { weight: 600, width });
  }

  label(id: string, s: string, width?: number): SNode {
    return this.text(id, s, 12, 16, MUTED, { width });
  }

  rect(id: string, name: string, w: number, h: number, fill: string, radius: number, extra: Record<string, unknown> = {}): SNode {
    return { id, type: "rectangle", name, size: [w, h], __fixed: true, fills: solid(fill), radius, ...extra };
  }

  /** A swatch's paint: the colour, a hairline around near-white. */
  swatch(id: string, name: string, w: number, h: number, css: string, radius: number): SNode {
    const c = cssColor(css);
    const hex = c ? toHex(c) : "#000000";
    const n = this.rect(id, name, w, h, hex, radius);
    if (!c || luminance(c) > 0.88) {
      n.strokes = solid(LINE);
      n.stroke = { weight: 1, align: "inside" };
    }
    return n;
  }

  item(ref: ItemRef, node: SNode): SNode {
    this.items.set(node.id, ref);
    return node;
  }

  chip(kind: ItemKind, label: string): SNode {
    const id = `sys:add:${kind}`;
    this.chips.set(id, kind);
    return this.frame(id, `Add ${kind}`, "horizontal", 6, [8, 14, 8, 14], [this.text(`${id}:t`, `+  ${label}`, 13, 18, "#3d3d42", { weight: 500 })], { fills: solid(SOFT), radius: 8, layout: { cross: "center" } });
  }

  sub(id: string, s: string): SNode {
    return this.text(id, s, 22, 28, INK, { weight: 600 });
  }

  card(key: SectionKey, title: string, note: string, rest: SNode[]): SNode {
    const id = sectionId(key);
    this.sections.set(id, key);
    const kids = [this.text(`${id}:title`, title, 40, 48, INK, { weight: 600 }), this.text(`${id}:note`, note, 15, 22, MUTED, { width: INNER }), ...rest];
    const n = this.frame(id, title, "vertical", 32, 56, kids, { fills: solid("#ffffff"), radius: 24, layout: { width: "fixed" } });
    n.size = [COLUMN_WIDTH, 10];
    n.__fixed = true;
    return n;
  }
}

/** "Saans", 500 → the face name a design tool shows, when the fonts here do not say. */
function faceName(weight: number): string {
  return ({ 100: "Thin", 200: "Extra Light", 300: "Light", 500: "Medium", 600: "Semi Bold", 700: "Bold", 800: "Extra Bold", 900: "Black" } as Record<number, string>)[weight] ?? "Regular";
}

const px = (v: string) => cssLengthPx(v.trim()) ?? null;
const num = (v: number) => String(Math.round(v * 100) / 100);

// ------------------------------------------------------------ sections

function tokens(b: Builder, doc: Doc): SNode {
  const s = doc.system;
  const k = "sys:tokens";
  const palette = scaleTokens(s, "color").map((t) => {
    const ref: ItemRef = { kind: "color", key: t.name };
    const id = `sys:color:${t.name}`;
    const css = resolveValue(s, t.value);
    const c = cssColor(css);
    return b.item(ref, b.frame(id, tokenLabel(t.name), "vertical", 6, 0, [b.swatch(`${id}:sw`, t.name, 160, 96, css, 12), b.strong(`${id}:name`, tokenLabel(t.name), 160), b.label(`${id}:val`, `${c ? toHex(c).toUpperCase() : t.value}\n${t.name}`, 160)]));
  });
  const spacing = scaleTokens(s, "spacing").map((t) => {
    const id = `sys:spacing:${t.name}`;
    const v = px(resolveValue(s, t.value)) ?? 0;
    return b.item({ kind: "spacing", key: t.name }, b.frame(id, tokenLabel(t.name), "horizontal", 16, 0, [b.strong(`${id}:name`, tokenLabel(t.name), 220), b.rect(`${id}:bar`, "bar", Math.max(1, Math.min(v * 4, 640)), 16, BAR, 3), b.label(`${id}:val`, `${t.value}  ·  ${t.name}`)], { layout: { cross: "center" } }));
  });
  const radii = scaleTokens(s, "radius").map((t) => {
    const id = `sys:radius:${t.name}`;
    const v = px(resolveValue(s, t.value)) ?? 0;
    return b.item({ kind: "radius", key: t.name }, b.frame(id, tokenLabel(t.name), "vertical", 6, 0, [b.rect(`${id}:sw`, "radius", 96, 96, SOFT, Math.min(v, 48), { strokes: solid(BAR), stroke: { weight: 1, align: "inside" } }), b.strong(`${id}:name`, tokenLabel(t.name), 120), b.label(`${id}:val`, t.value, 120)]));
  });
  const shadows = scaleTokens(s, "shadow").map((t) => {
    const id = `sys:shadow:${t.name}`;
    return b.item({ kind: "shadow", key: t.name }, b.frame(id, tokenLabel(t.name), "vertical", 10, 0, [b.rect(`${id}:sw`, "shadow", 160, 96, "#ffffff", 12, { effects: shadowEffects(resolveValue(s, t.value)) }), b.strong(`${id}:name`, tokenLabel(t.name), 200), b.label(`${id}:val`, t.value, 200)]));
  });
  const rest: SNode[] = [b.sub(`${k}:palette`, "Palette"), b.wrap(`${k}:palette-row`, "Palette", INNER, 24, palette), b.chip("color", "Add colour")];
  rest.push(b.sub(`${k}:spacing`, "Spacing"), b.frame(`${k}:spacing-list`, "Spacing", "vertical", 10, 0, spacing), b.chip("spacing", "Add spacing"));
  rest.push(b.sub(`${k}:radii`, "Radii"), b.wrap(`${k}:radii-row`, "Radii", INNER, 24, radii), b.chip("radius", "Add radius"));
  rest.push(b.sub(`${k}:shadows`, "Shadows"), b.wrap(`${k}:shadow-row`, "Shadows", INNER, 40, shadows), b.chip("shadow", "Add shadow"));
  return b.card("tokens", "Token library", GROUPS[0].sections[0].note, rest);
}

/** A CSS box-shadow list as Pubd drop shadows. */
export function shadowEffects(css: string): Record<string, unknown>[] {
  const out: Record<string, unknown>[] = [];
  for (const part of css.split(/,(?![^(]*\))/)) {
    const inset = /\binset\b/.test(part);
    const color = /(#[\da-f]{3,8}|rgba?\([^)]*\))/i.exec(part)?.[1] ?? "#00000040";
    const nums = part
      .replace(color, "")
      .replace("inset", "")
      .trim()
      .split(/\s+/)
      .map((v) => px(v))
      .filter((v): v is number => v !== null);
    const c = cssColor(color);
    out.push({ type: inset ? "inner-shadow" : "drop-shadow", color: c ? toHex(c) : "#00000040", offset: [nums[0] ?? 0, nums[1] ?? 0], radius: nums[2] ?? 0, spread: nums[3] ?? 0 });
  }
  return out;
}

function fontsSection(b: Builder, doc: Doc): SNode {
  const s = doc.system;
  const cards = fonts(s).map((t) => {
    const id = `sys:font:${t.name}`;
    const family = fontLabel(s, t);
    const def = s.fonts.find((f) => f.token === t.name);
    const weights = b.ctx.weights(family);
    const w0 = weights.includes(400) ? 400 : (weights[0] ?? 400);
    const here = weights.length ? weights.map((w) => `${w} ${b.ctx.face(family, w)}`).join(", ") : "not on this computer";
    return b.item(
      { kind: "font", key: t.name },
      b.frame(id, family, "vertical", 8, 0, [b.text(`${id}:aa`, "Aa", 72, 80, INK, { family, weight: w0 }), b.strong(`${id}:name`, family, 320), b.label(`${id}:val`, `${t.name} · ${def?.fallback ?? "sans-serif"}\n${here}`, 320)]),
    );
  });
  return b.card("fonts", "Fonts", GROUPS[0].sections[1].note, [b.wrap("sys:fonts:row", "Fonts", INNER, 56, cards), b.chip("font", "Add font")]);
}

function iconsSection(b: Builder, doc: Doc): SNode {
  const tiles = doc.system.icons.map((icon) => {
    const id = `sys:icon:${icon.name}`;
    const drawn = pubdFromSvg(icon.svg, `${id}:svg`, 32) ?? b.rect(`${id}:svg`, "icon", 32, 32, SOFT, 4);
    drawn.__fixed = true;
    return b.item(
      { kind: "icon", key: icon.name },
      b.frame(id, icon.name, "vertical", 8, 0, [b.frame(`${id}:tile`, "tile", "horizontal", 0, 20, [drawn], { fills: solid(SOFT), radius: 12, layout: { main: "center", cross: "center" } }), b.label(`${id}:name`, icon.label || icon.name, 96)]),
    );
  });
  const rest: SNode[] = [b.wrap("sys:icons:row", "Icons", INNER, 20, tiles)];
  if (!tiles.length) rest.push(b.label("sys:icons:empty", "No icons yet. Select icons in the reference and right-click, Add icons.", INNER));
  return b.card("icons", "Icons", GROUPS[0].sections[2].note, rest);
}

function containersSection(b: Builder, doc: Doc): SNode {
  const rows = containers(doc.system).map((c) => {
    const id = `sys:container:${c.key}`;
    const w = px(c.maxWidth) ?? 960;
    return b.item(
      { kind: "container", key: c.key },
      b.frame(id, c.label, "horizontal", 16, 0, [b.strong(`${id}:name`, c.label, 200), b.rect(`${id}:bar`, "width", Math.max(8, Math.min(w * 0.5, 720)), 20, BAR, 4), b.label(`${id}:val`, `max ${c.maxWidth} · padding ${c.padding.base ?? ""}`)], { layout: { cross: "center" } }),
    );
  });
  return b.card("containers", "Container sizes", GROUPS[0].sections[3].note, [b.frame("sys:containers:list", "Containers", "vertical", 14, 0, rows), b.chip("container", "Add container")]);
}

function semanticSection(b: Builder, doc: Doc): SNode {
  const s = doc.system;
  // Each role in every colour context (Light mode, Dark mode, ...): a swatch per context,
  // the contexts named once above them.
  const contexts = colorContexts(s);
  const rows = semanticRoles(s).map((r) => {
    const id = `sys:role:${r.key}`;
    const target = rolePalette(s, r.key);
    const css = roleColor(s, r);
    const c = cssColor(css);
    const swatches = contexts.map((x) => {
      const v = x.key === "default" ? css : resolveValue(s, tokenValue(s, roleToken(x.key, r.key)) ?? css);
      return b.swatch(x.key === "default" ? `${id}:sw` : `${id}:sw:${x.key}`, `${r.key} · ${x.label}`, 40, 40, v, 20);
    });
    const kids: SNode[] = contexts.length > 1 ? [b.frame(`${id}:contexts`, "contexts", "horizontal", 6, 0, swatches)] : swatches;
    return b.item(
      { kind: "role", key: r.key },
      b.frame(id, r.label, "horizontal", 14, 0, [...kids, b.frame(`${id}:text`, "text", "vertical", 2, 0, [b.strong(`${id}:name`, r.label, 420 - (contexts.length - 1) * 46), b.label(`${id}:val`, `color-${r.key} → ${target ? tokenLabel(target) : c ? toHex(c).toUpperCase() : css}`, 420 - (contexts.length - 1) * 46)])], { layout: { cross: "center" } }),
    );
  });
  const head: SNode[] = contexts.length > 1 ? [b.label("sys:semantic:contexts", `${Publr.t("Swatches, left to right")}: ${contexts.map((x) => x.label).join(", ")}`, INNER)] : [];
  return b.card("semantic", "Semantic colors", GROUPS[1].sections[0].note, [...head, b.wrap("sys:semantic:row", "Roles", INNER, 28, rows), b.chip("role", "Add role")]);
}

function typographySection(b: Builder, doc: Doc): SNode {
  const s = doc.system;
  const rows = fontRoles(s).map((r) => {
    const id = `sys:fontRole:${r.token}`;
    const family = familyOf(s, r.token);
    return b.item({ kind: "fontRole", key: r.token }, b.frame(id, r.label, "horizontal", 24, 0, [b.text(`${id}:aa`, "Aa", 40, 48, INK, { family }), b.frame(`${id}:text`, "text", "vertical", 2, 0, [b.strong(`${id}:name`, r.label, 220), b.label(`${id}:val`, `${r.token} → ${family || r.target}`, 220)])], { layout: { cross: "center" } }));
  });
  return b.card("typography", "Typography", GROUPS[1].sections[1].note, [b.wrap("sys:typography:row", "Roles", INNER, 40, rows)]);
}

function typeScaleSection(b: Builder, doc: Doc): SNode {
  const s = doc.system;
  const rows = s.typeScale.map((e) => {
    const id = `sys:type:${e.key}`;
    const family = entryFamily(s, e);
    const size = px(scaleValue(s, e.size, "text-")) ?? 16;
    const lhText = scaleValue(s, e.lineHeight, "leading-");
    const lh = lhText ? (px(lhText) ?? (Number(lhText) ? Number(lhText) * size : null)) : null;
    const ls = px(scaleValue(s, e.letterSpacing, "tracking-")) ?? 0;
    const tcase = e.textTransform === "uppercase" ? "upper" : e.textTransform === "lowercase" ? "lower" : e.textTransform === "capitalize" ? "title" : "none";
    const spec = b.frame(
      `${id}:spec`,
      "spec",
      "vertical",
      4,
      0,
      [b.strong(`${id}:name`, e.label, 260), b.label(`${id}:font`, `${family || e.fontRole} ${e.weight}`, 260), b.label(`${id}:val`, `${num(size)} / ${lh === null ? "auto" : num(lh)} · ${num(ls)}${e.textTransform ? ` · ${e.textTransform}` : ""}`, 260)],
      { layout: { width: "fixed" } },
    );
    spec.size = [280, 10];
    spec.__fixed = true;
    const specimen = b.text(`${id}:sample`, b.ctx.sample, size, lh, INK, { family, weight: e.weight, width: 780, extra: { letterSpacing: ls, case: tcase } });
    return b.item({ kind: "type", key: e.key }, b.frame(id, e.label, "horizontal", 40, 0, [spec, specimen]));
  });
  return b.card("typescale", "Type scale", GROUPS[1].sections[2].note, [b.frame("sys:typescale:list", "Type scale", "vertical", 28, 0, rows), b.chip("type", "Add style")]);
}

function blocksSection(b: Builder, doc: Doc): SNode {
  const tiles = b.ctx.blocks.map((block) => {
    const id = `sys:block:${block.type}`;
    const prim = doc.primitives[block.type];
    const kids: SNode[] = [b.strong(`${id}:name`, block.label, 220), b.label(`${id}:cat`, block.category, 220), b.label(`${id}:val`, prim ? `Default: ${prim.name}` : "Default: the block's starter", 220)];
    if (prim) kids.push(renamed(prim.node, `${id}:node`));
    const n = b.frame(id, block.label, "vertical", 6, 16, kids, { fills: solid(SOFT), radius: 12 });
    return b.item({ kind: "block", key: block.type }, n);
  });
  return b.card("blocks", "Primitive blocks", GROUPS[2].sections[0].note, [b.wrap("sys:blocks:row", "Blocks", INNER, 16, tiles)]);
}

/** A component carried into the scene: its ids made the scene's, its place reset. */
function renamed(node: Record<string, unknown>, id: string): SNode {
  let k = 0;
  const walk = (n: Record<string, unknown>, nid: string): SNode => {
    const { component: _c, overrides: _o, props: _p, ...rest } = n;
    const out: SNode = { ...(rest as SNode), id: nid, type: rest.type === "component" || rest.type === "instance" || rest.type === "component-set" ? "frame" : String(rest.type) };
    if (Array.isArray(n.children)) out.children = (n.children as Record<string, unknown>[]).map((c) => walk(c, `${id}:${k++}`));
    return out;
  };
  const root = walk(node, id);
  root.transform = [1, 0, 0, 1, 0, 0];
  root.__fixed = true;
  return root;
}

function breakpointsSection(b: Builder, doc: Doc): SNode {
  const s = doc.system;
  const list = styleBreakpoints(s);
  const colors: Record<string, string> = { mobile: "#8fb7a5", tablet: "#a7b6d9", desktop: "#c2a6d6" };
  const rows = list.map((bp, i) => {
    const id = `sys:breakpoint:${bp.key}`;
    const device = breakpointDevice(s, bp.key);
    const w = px(bp.viewport) ?? 0;
    return b.item(
      { kind: "breakpoint", key: bp.key },
      b.frame(id, bp.label, "horizontal", 16, 0, [b.strong(`${id}:name`, bp.label, 200), b.label(`${id}:device`, device[0].toUpperCase() + device.slice(1), 90), b.rect(`${id}:bar`, "width", Math.max(8, Math.min(w * 0.4, 640)), 16, colors[device] ?? BAR, 3), b.label(`${id}:val`, `${bp.viewport}  ${breakpointRange(list, i)}`)], { layout: { cross: "center" } }),
    );
  });
  return b.card("breakpoints", "Breakpoints", GROUPS[3].sections[0].note, [b.frame("sys:breakpoints:list", "Breakpoints", "vertical", 14, 0, rows), b.chip("breakpoint", "Add breakpoint")]);
}

function listSection(b: Builder, key: "patterns" | "templates", label: string, note: string): SNode {
  return b.card(key, label, note, [b.label(`sys:${key}:empty`, key === "patterns" ? "This project has no patterns yet." : "This project has no templates yet.", INNER)]);
}

/** The whole scene for `doc`. */
export function buildScene(doc: Doc, ctx: SceneContext): Scene {
  const b = new Builder(ctx);
  const columns: SNode[][] = [
    [tokens(b, doc), fontsSection(b, doc), iconsSection(b, doc), containersSection(b, doc)],
    [semanticSection(b, doc), typographySection(b, doc), typeScaleSection(b, doc)],
    [blocksSection(b, doc)],
    [breakpointsSection(b, doc), listSection(b, "patterns", "Patterns", GROUPS[3].sections[1].note), listSection(b, "templates", "Templates", GROUPS[3].sections[2].note)],
  ];
  const roots = columns.map((cards, i) => {
    const g = GROUPS[i];
    const n = b.frame(`sys:column:${g.key}`, g.label, "vertical", 96, 0, cards);
    n.transform = [1, 0, 0, 1, i * (COLUMN_WIDTH + COLUMN_GAP), 0];
    return n;
  });
  return { roots, items: b.items, sections: b.sections, chips: b.chips };
}

// ------------------------------------------------------------ changes

/** The node as the engine takes it: `__fixed` dropped at every level. */
export function clean(n: SNode): Record<string, unknown> {
  const { __fixed: _f, children, ...rest } = n;
  const out: Record<string, unknown> = { ...rest };
  if (children) out.children = children.map(clean);
  return out;
}

/** The keys of a node the data decides (a node in an auto layout has its place and,
 * unless fixed, its size from the layout). */
function ownKeys(n: SNode, top: boolean): string[] {
  return Object.keys(n).filter((k) => k !== "id" && k !== "children" && k !== "__fixed" && (k !== "transform" || top) && (k !== "size" || n.__fixed));
}

const same = (a: unknown, b: unknown) => JSON.stringify(a) === JSON.stringify(b);

/** The changes that turn the scene `from` into `to` under node `parent`. */
export function diff(from: SNode[], to: SNode[], parent = PAGE_ID): Record<string, unknown>[] {
  const out: Record<string, unknown>[] = [];
  const top = parent === PAGE_ID;
  const wanted = new Set(to.map((n) => n.id));
  const old = new Map(from.map((n) => [n.id, n]));
  const now = from.map((n) => n.id).filter((id) => wanted.has(id));
  for (const n of from) if (!wanted.has(n.id)) out.push({ op: "delete", node: n.id });
  to.forEach((n, i) => {
    const at = now.indexOf(n.id);
    if (at < 0) {
      out.push({ op: "insert", parent, index: i, node: clean(n) });
      now.splice(i, 0, n.id);
      return;
    }
    if (at !== i) {
      out.push({ op: "move", node: n.id, parent, index: i });
      now.splice(at, 1);
      now.splice(i, 0, n.id);
    }
    const prev = old.get(n.id)!;
    // A node whose type changed is put in again.
    if (prev.type !== n.type) {
      out.push({ op: "delete", node: n.id }, { op: "insert", parent, index: i, node: clean(n) });
      return;
    }
    const props: Record<string, unknown> = {};
    const keys = new Set([...ownKeys(prev, top), ...ownKeys(n, top)]);
    for (const k of keys) if (!same(prev[k], n[k])) props[k] = n[k] ?? null;
    if (Object.keys(props).length) out.push({ op: "set", node: n.id, props });
    out.push(...diff(prev.children ?? [], n.children ?? [], n.id));
  });
  return out;
}
