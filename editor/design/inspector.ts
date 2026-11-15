// What the Design tab shows of the selection, worked out from the nodes' Pubd fields
// (doc.ts NodeInfo) as plain strings and flags, in the editor's sections: the header,
// Position, Layout, Appearance, Typography, Fill, Stroke, Effects, Layout guide, Export.
// Numbers are shown as the editor shows them: at most two decimals, no trailing zeros.

import type { NodeInfo, PropDef } from "./doc";

export type PaintRow = {
  key: string;
  /** CSS for the swatch. */
  swatch: string;
  /** "0D99FF", "Linear", "Image", or the style's name. */
  label: string;
  /** "100" ("" when a style stands for it). */
  opacity: string;
  visible: boolean;
  /** Follows a style: one field, no opacity. */
  style: boolean;
  /** "solid", "linear", "image"…: a solid's label is its hex and can be typed. */
  type: string;
  /** Bound to a colour variable: its name ("" none; variables.ts fills it in). */
  variable: string;
};

/** A collection a layer sets the mode of (Appearance), as its row shows it. */
export type ModeRow = { collection: string; name: string; mode: string; options: { value: string; label: string }[] };
/** A collection whose mode a layer could set (the Appearance mode menu). */
export type ModeMenu = { collection: string; name: string; modes: { id: string; name: string }[] };

export type EffectRow = {
  key: string;
  /** Pubd type: "drop-shadow", "layer-blur"… */
  type: string;
  name: string;
  icon: string;
  visible: boolean;
  detail: string;
  shadow: boolean;
  x: string;
  y: string;
  radius: string;
  spread: string;
  /** The shadow's colour (hex, no #), its opacity and swatch. */
  hex: string;
  alpha: string;
  swatch: string;
};

/** A component property of an instance, as its control shows it. */
export type PropRow = { id: string; name: string; type: string; value: string; on: boolean; options: { value: string; label: string }[] };

export type Inspector = {
  /** The header: "Frame", "Text", an instance's main component's name, "Mixed". */
  title: string;
  /** Under the header of an instance: where its main component is. */
  subtitle: string;
  kind: string;
  purple: boolean;
  multi: boolean;
  count: number;
  x: string;
  y: string;
  w: string;
  h: string;
  rotation: string;
  /** Inside a frame (not auto layout): its constraints. */
  constraints: { h: string; v: string } | null;
  /** Containers: the auto layout (flow "free" when none). */
  container: boolean;
  flow: "free" | "vertical" | "horizontal" | "grid";
  gap: string;
  crossGap: string;
  padH: string;
  padV: string;
  /** Padding by side: top, right, bottom, left. */
  pads: string[];
  /** The alignment box's cell: column and row (0..2), -1 when spread. */
  alignCol: number;
  alignRow: number;
  /** Auto layout on (the frame has `layout`). */
  auto: boolean;
  wrap: boolean;
  main: string;
  cross: string;
  clip: boolean;
  /** A child of auto layout (its W and H have sizing menus). */
  inFlow: boolean;
  /** Sizing in auto layout: "fixed", "hug" or "fill" (the W and H fields' menus). */
  wSizing: string;
  hSizing: string;
  /** Text: how it resizes. */
  textResize: string;
  opacity: string;
  blend: string;
  visible: boolean;
  locked: boolean;
  /** Pubd blend key ("pass-through", "multiply"). */
  blendKey: string;
  radius: string | null;
  /** By corner: top-left, top-right, bottom-right, bottom-left. */
  radii: string[];
  typography: {
    family: string;
    style: string;
    size: string;
    lineHeight: string;
    letterSpacing: string;
    align: string;
    valign: string;
    styleName: string;
    decoration: string;
    textCase: string;
    /** The family or the style is not among the fonts here. */
    missing: boolean;
  } | null;
  fills: PaintRow[];
  fillStyle: string;
  strokes: PaintRow[];
  strokeWeight: string;
  strokeAlign: string;
  /** "all", one side, or "custom"; the sides' weights (top, right, bottom, left). */
  strokeSides: string;
  strokeSideWeights: string[];
  /** Rectangles and frames: stroke sides apply. */
  strokeSidesApply: boolean;
  effects: EffectRow[];
  /** The effect style the layer follows ("" none): its name shows in place of the effects. */
  effectStyle: string;
  /** An instance's component properties (one selected), and whether it has overrides. */
  props: PropRow[];
  instanceId: string;
  hasOverrides: boolean;
  /** Inside an instance: structure cannot change. */
  inInstance: boolean;
  /** The main component's id (instances). */
  mainId: string;
  grids: { key: string; name: string; visible: boolean }[];
  /** The fields bound to variables, by key ("gap", "padding/0", "radius", "opacity",
   * "width", "stroke/weight", "style/size", ...): the variable's name. variables.ts fills
   * these in. */
  vars: Record<string, string>;
  /** The modes the layer sets, and the collections it could set one of. */
  modeRows: ModeRow[];
  modeMenu: ModeMenu[];
};

const TITLES: Record<string, string> = {
  frame: "Frame",
  group: "Group",
  section: "Section",
  component: "Component",
  "component-set": "Component set",
  instance: "Instance",
  rectangle: "Rectangle",
  ellipse: "Ellipse",
  line: "Line",
  vector: "Vector",
  text: "Text",
  star: "Star",
  polygon: "Polygon",
  boolean: "Boolean",
  slice: "Slice",
};

/** A number as the panel writes it. */
export function num(v: number): string {
  if (!Number.isFinite(v)) return "0";
  const r = Math.round(v * 100) / 100;
  return String(Object.is(r, -0) ? 0 : r);
}

const cap = (s: string) => (s ? s[0].toUpperCase() + s.slice(1) : s);

/** "#rrggbb", "#rrggbbaa" or [r, g, b, a?] in 0..1: hex (upper case, no #) and alpha. */
export function colorOf(c: unknown): { hex: string; alpha: number; css: string } {
  let r = 0;
  let g = 0;
  let b = 0;
  let a = 1;
  if (typeof c === "string" && c.startsWith("#")) {
    const h = c.slice(1);
    r = parseInt(h.slice(0, 2), 16) / 255;
    g = parseInt(h.slice(2, 4), 16) / 255;
    b = parseInt(h.slice(4, 6), 16) / 255;
    a = h.length >= 8 ? parseInt(h.slice(6, 8), 16) / 255 : 1;
  } else if (Array.isArray(c)) {
    [r, g, b] = c as number[];
    a = (c[3] as number | undefined) ?? 1;
  }
  const byte = (v: number) => Math.round(Math.max(0, Math.min(1, v)) * 255);
  const hex = [r, g, b].map((v) => byte(v).toString(16).padStart(2, "0")).join("").toUpperCase();
  return { hex, alpha: a, css: `rgba(${byte(r)},${byte(g)},${byte(b)},${a})` };
}

type Paint = { type?: string; color?: unknown; opacity?: number; visible?: boolean; stops?: { at: number; color: unknown }[] };

function paintRows(paints: Paint[] | undefined, styleName: string): PaintRow[] {
  const list = paints ?? [];
  if (styleName && list.length) {
    const first = list[0];
    return [{ key: "style", swatch: swatchOf(first), label: styleName, opacity: "", visible: first.visible !== false, style: true, type: first.type ?? "solid", variable: "" }];
  }
  // The panel lists the top-most paint first.
  return [...list].reverse().map((p, k) => {
    const opacity = p.opacity ?? 1;
    if (p.type === "solid") {
      const c = colorOf(p.color);
      return { key: String(k), swatch: c.css, label: c.hex, opacity: num(Math.round(c.alpha * opacity * 100)), visible: p.visible !== false, style: false, type: "solid", variable: "" };
    }
    const label = p.type === "image" ? "Image" : p.type === "pattern" ? "Pattern" : cap(p.type ?? "Paint");
    return { key: String(k), swatch: swatchOf(p), label, opacity: num(Math.round(opacity * 100)), visible: p.visible !== false, style: false, type: p.type ?? "solid", variable: "" };
  });
}

function swatchOf(p: Paint): string {
  if (p.type === "solid") return colorOf(p.color).css;
  if (p.stops?.length) {
    const stops = p.stops.map((s) => `${colorOf(s.color).css} ${Math.round(s.at * 100)}%`).join(", ");
    return p.type === "radial" || p.type === "diamond" ? `radial-gradient(circle, ${stops})` : p.type === "angular" ? `conic-gradient(${stops})` : `linear-gradient(135deg, ${stops})`;
  }
  if (p.type === "image") return "repeating-conic-gradient(#bbb 0 25%, #eee 0 50%) 0 0 / 8px 8px";
  return "transparent";
}

const EFFECT_NAMES: Record<string, [string, string]> = {
  "drop-shadow": ["Drop shadow", "effect-shadow"],
  "inner-shadow": ["Inner shadow", "effect-shadow"],
  "layer-blur": ["Layer blur", "effect-blur"],
  "background-blur": ["Background blur", "effect-blur"],
  noise: ["Noise", "effect-blur"],
  texture: ["Texture", "effect-blur"],
};

function lineHeight(v: unknown): string {
  if (!v || v === "auto") return "Auto";
  if (typeof v === "object" && v && "px" in v) return num((v as { px: number }).px);
  if (typeof v === "object" && v && "percent" in v) return `${num((v as { percent: number }).percent)}%`;
  return "Auto";
}

function letterSpacing(v: unknown): string {
  if (typeof v === "number") return v ? num(v) : "0%";
  if (typeof v === "object" && v && "percent" in v) return `${num((v as { percent: number }).percent)}%`;
  return "0%";
}

/** The Design tab's model for the selected nodes (`count` of them; `infos` for up to
 * 50), with the selection's page box for a multiple selection. */
export function inspect(
  infos: NodeInfo[],
  count: number,
  box: number[] | null,
  hasFace: (family: string, style: string) => boolean = () => true,
  /** A layer's rotation on the canvas (Rotation shows it, ancestors' included). */
  canvasRotation: (id: string) => number | null = () => null,
): Inspector {
  const first = infos[0];
  const n = first.node;
  const multi = count > 1;
  const type = n.type;
  const t = (n.transform as number[] | undefined) ?? [1, 0, 0, 1, 0, 0];
  const size = (n.size as number[] | undefined) ?? [0, 0];
  const layout = n.layout as Record<string, unknown> | undefined;
  const parentLayout = first.parent?.layout as Record<string, unknown> | null | undefined;
  const container = ["frame", "component", "component-set", "instance", "section"].includes(type);
  const mode = (layout?.mode as string | undefined) ?? "";
  const pad = (layout?.padding as number[] | undefined) ?? [0, 0, 0, 0];
  const sizing = n.sizing as { w?: string; h?: string } | undefined;
  const sizingLabel = (axis: "w" | "h") => {
    const own = sizing?.[axis];
    if (own === "fill") return "fill";
    if (own === "hug" || (axis === "w" ? layout?.width : layout?.height) === "hug") return "hug";
    // A text sized by its words: auto width hugs both ways, auto height hugs its height.
    if (type === "text" && (n.resize === "width-and-height" || (axis === "h" && n.resize === "height"))) return "hug";
    return "fixed";
  };
  const inFrame = first.parent && first.parent.type !== "page" && first.parent.type !== "group" && first.parent.type !== "section";
  const absolute = n.absolute === true;
  const cons = n.constraints as { h?: string; v?: string } | undefined;
  const hNames: Record<string, string> = { left: "Left", right: "Right", "left-right": "Left & right", center: "Center", scale: "Scale" };
  const vNames: Record<string, string> = { top: "Top", bottom: "Bottom", "top-bottom": "Top & bottom", center: "Center", scale: "Scale" };
  const style = n.style as Record<string, unknown> | undefined;
  const typo = type === "text"
    ? {
        family: String(style?.family ?? ""),
        style: String(style?.fontStyle ?? (style?.weight && style.weight !== 400 ? `${style.weight}` : "Regular")),
        size: num((style?.size as number | undefined) ?? 16),
        lineHeight: lineHeight(style?.lineHeight),
        letterSpacing: letterSpacing(style?.letterSpacing),
        align: String(n.align ?? "left"),
        valign: String(n.valign ?? "top"),
        styleName: first.styleNames.text ?? "",
        decoration: String(style?.decoration ?? "none"),
        textCase: String(style?.case ?? "none"),
        missing: !hasFace(String(style?.family ?? ""), String(style?.fontStyle ?? "Regular")),
      }
    : null;
  const radius = n.radius;
  const radiusText = ["rectangle", "frame", "component", "component-set", "instance", "polygon", "star"].includes(type)
    ? Array.isArray(radius)
      ? (radius as number[]).every((r) => r === radius[0])
        ? num(radius[0] as number)
        : "Mixed"
      : num((radius as number | undefined) ?? 0)
    : null;
  const stroke = n.stroke as { weight?: number; align?: string } | undefined;
  const defaultAlign = container || type === "rectangle" ? "inside" : "center";
  const effects = ((n.effects as { type: string; visible?: boolean; radius?: number; offset?: number[]; spread?: number; color?: unknown }[] | undefined) ?? []).map((e, k) => {
    const c = colorOf(e.color ?? "#00000040");
    return {
      key: String(k),
      type: e.type,
      name: EFFECT_NAMES[e.type]?.[0] ?? cap(e.type),
      icon: EFFECT_NAMES[e.type]?.[1] ?? "effect-shadow",
      visible: e.visible !== false,
      detail: e.radius !== undefined ? num(e.radius) : "",
      shadow: e.type === "drop-shadow" || e.type === "inner-shadow",
      x: num(e.offset?.[0] ?? 0),
      y: num(e.offset?.[1] ?? 0),
      radius: num(e.radius ?? 0),
      spread: num(e.spread ?? 0),
      hex: c.hex,
      alpha: num(Math.round(c.alpha * 100)),
      swatch: c.css,
    };
  });
  const grids = ((n.grids as { type: string; count?: number; visible?: boolean }[] | undefined) ?? []).map((g, k) => ({
    key: String(k),
    name: g.type === "grid" ? `Grid (${num((g as { size?: number }).size ?? 10)}px)` : `${g.count ?? 1} ${g.type === "rows" ? "rows" : "columns"}`,
    visible: g.visible !== false,
  }));
  const rotationOf = (i: NodeInfo) => {
    const m = (i.node.transform as number[] | undefined) ?? [1, 0, 0, 1, 0, 0];
    return canvasRotation(i.node.id) ?? (Math.atan2(-m[1], m[0]) * 180) / Math.PI;
  };
  const rotation = rotationOf(first);
  let title = TITLES[type] ?? cap(type);
  if (type === "instance") title = first.main || n.name || "Instance";
  if (multi) title = infos.every((i) => i.node.type === type) ? `${count} ${title.toLowerCase()}s` : "Mixed";
  const mixed = (get: (i: NodeInfo) => string) => (infos.every((i) => get(i) === get(first)) ? get(first) : "Mixed");
  return {
    title,
    // Pubd leaves `component` out when the main is not in the document.
    subtitle: type === "instance" && !multi ? (typeof n.component === "string" ? "From this file" : "From a library") : "",
    kind: type,
    purple: type === "instance" || type === "component" || type === "component-set",
    multi,
    count,
    // Each layer's place in its parent, as Figma shows it: one value, or Mixed.
    x: multi ? mixed((i) => num(((i.node.transform as number[] | undefined) ?? [1, 0, 0, 1, 0, 0])[4])) : num(t[4]),
    y: multi ? mixed((i) => num(((i.node.transform as number[] | undefined) ?? [1, 0, 0, 1, 0, 0])[5])) : num(t[5]),
    w: multi ? mixed((i) => num(((i.node.size as number[] | undefined) ?? [0, 0])[0])) : num(size[0]),
    h: multi ? mixed((i) => num(((i.node.size as number[] | undefined) ?? [0, 0])[1])) : num(size[1]),
    rotation: multi ? mixed((i) => num(rotationOf(i))) : num(rotation),
    constraints: inFrame && (!parentLayout || absolute) ? { h: hNames[cons?.h ?? "left"] ?? "Left", v: vNames[cons?.v ?? "top"] ?? "Top" } : null,
    container,
    flow: mode === "horizontal" ? "horizontal" : mode === "vertical" ? "vertical" : mode === "grid" ? "grid" : "free",
    gap: layout?.main === "space-between" ? "Auto" : num((layout?.gap as number | undefined) ?? 0),
    crossGap: num((layout?.crossGap as number | undefined) ?? 0),
    padH: pad[1] === pad[3] ? num(pad[3]) : "Mixed",
    padV: pad[0] === pad[2] ? num(pad[0]) : "Mixed",
    pads: pad.map((v) => num(v)),
    alignCol: alignCell(layout, "col"),
    alignRow: alignCell(layout, "row"),
    auto: !!layout,
    wrap: layout?.wrap === true,
    main: String(layout?.main ?? "start"),
    cross: String(layout?.cross ?? "start"),
    clip: n.clip === true,
    inFlow: !!parentLayout && !absolute,
    wSizing: sizingLabel("w"),
    hSizing: sizingLabel("h"),
    textResize: type === "text" ? String(n.resize ?? "fixed") : "",
    opacity: multi ? mixed((i) => num(Math.round(((i.node.opacity as number | undefined) ?? 1) * 100))) : num(Math.round(((n.opacity as number | undefined) ?? 1) * 100)),
    blend: cap(String(n.blend ?? "pass-through").replace(/-/g, " ")),
    visible: n.visible !== false,
    locked: n.locked === true,
    blendKey: String(n.blend ?? "pass-through"),
    radius: radiusText,
    radii: Array.isArray(radius) ? (radius as number[]).map((r) => num(r)) : [0, 1, 2, 3].map(() => num((radius as number | undefined) ?? 0)),
    typography: typo,
    fills: paintRows(n.fills as Paint[] | undefined, first.styleNames.fill ?? ""),
    fillStyle: first.styleNames.fill ?? "",
    strokes: paintRows(n.strokes as Paint[] | undefined, first.styleNames.stroke ?? ""),
    strokeWeight: num(stroke?.weight ?? 1),
    strokeAlign: cap(stroke?.align ?? defaultAlign),
    strokeSides: strokeSidesOf(n.stroke as { sides?: number[]; weight?: number } | undefined),
    strokeSideWeights: ((n.stroke as { sides?: number[] } | undefined)?.sides ?? [0, 1, 2, 3].map(() => stroke?.weight ?? 1)).map((v) => num(v)),
    strokeSidesApply: ["rectangle", "frame", "component", "component-set", "instance"].includes(type),
    effects,
    effectStyle: multi ? "" : (first.styleNames.effect ?? ""),
    props: !multi && type === "instance" ? propRows(first.props, { ...first.variant, ...((n.props as Record<string, unknown> | undefined) ?? {}) }) : [],
    instanceId: type === "instance" ? n.id : (first.instance?.id ?? ""),
    hasOverrides: type === "instance" ? hasOverrides(n.overrides) : !!first.instance?.overrides?.length,
    inInstance: !!first.instance && type !== "instance",
    mainId: first.mainId,
    grids,
    vars: {},
    modeRows: [],
    modeMenu: [],
  };
}

function alignCell(layout: Record<string, unknown> | undefined, which: "col" | "row"): number {
  if (!layout) return 0;
  const at = (v: unknown) => (v === "center" ? 1 : v === "end" ? 2 : v === "space-between" ? -1 : 0);
  const horizontal = layout.mode !== "vertical";
  const main = at(layout.main);
  const cross = at(layout.cross);
  return which === "col" ? (horizontal ? main : cross) : horizontal ? cross : main;
}

function strokeSidesOf(stroke: { sides?: number[]; weight?: number } | undefined): string {
  const s = stroke?.sides;
  if (!s) return "all";
  if (s.every((v) => v === s[0])) return "all";
  const on = s.map((v) => v > 0);
  if (on.filter(Boolean).length === 1) return ["top", "right", "bottom", "left"][on.indexOf(true)];
  return "custom";
}

function hasOverrides(o: unknown): boolean {
  if (!o || typeof o !== "object") return false;
  return Object.values(o as Record<string, string[]>).some((keys) => Array.isArray(keys) && keys.length > 0);
}

/** An instance's properties as controls, in the order its component lists them (a set's
 * variant properties first: the set's, then the variant's own). */
function propRows(defs: PropDef[], values: Record<string, unknown>): PropRow[] {
  return defs
    .map((d) => {
      const key = d.type === "variant" ? d.name : d.id;
      const v = key in values ? values[key] : d.default;
      return {
        id: key,
        name: d.name.replace(/#[^#]*$/, ""),
        type: d.type,
        value: typeof v === "string" ? v : String(v ?? ""),
        on: v === true,
        options: ((d.options as unknown[] | undefined) ?? []).map((o) => ({ value: String(o), label: String(o) })),
      };
    });
}
