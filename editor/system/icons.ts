// Icons between the builder's shape (self-contained SVG markup) and the canvas (Pubd
// vectors): an icon taken from a design file becomes SVG from its resolved fill and
// stroke outlines; an icon's SVG is drawn on the canvas as vectors whose `geometry` is
// its paths. Filled paths only: a stroke that only SVG describes (no outline) is drawn
// as its fill, the gap named in the spec.
//
// Glue, not UI.

import { pubdColor, toHex } from "./color";

type N = Record<string, unknown>;
type Aff = [number, number, number, number, number, number];

const mul = (a: Aff, b: Aff): Aff => [a[0] * b[0] + a[2] * b[1], a[1] * b[0] + a[3] * b[1], a[0] * b[2] + a[2] * b[3], a[1] * b[2] + a[3] * b[3], a[0] * b[4] + a[2] * b[5] + a[4], a[1] * b[4] + a[3] * b[5] + a[5]];

function solidOf(paints: unknown): string {
  if (!Array.isArray(paints)) return "";
  for (const p of paints as N[]) {
    if (p.visible === false || p.type !== "solid") continue;
    const c = pubdColor(p.color);
    if (c) return toHex({ ...c, a: c.a * (typeof p.opacity === "number" ? p.opacity : 1) });
  }
  return "";
}

const fmt = (m: Aff) => m.map((v) => Math.round(v * 10000) / 10000).join(" ");

/** SVG markup of a Pubd node (an icon drawn in a design file), its own box the view box. */
export function svgFromPubd(root: N): string {
  const size = (root.size as number[]) ?? [24, 24];
  const out: string[] = [];
  const walk = (n: N, m: Aff) => {
    if (n.visible === false) return;
    const own = n === root ? ([1, 0, 0, 1, 0, 0] as Aff) : mul(m, ((n.transform as Aff) ?? [1, 0, 0, 1, 0, 0]) as Aff);
    const fill = solidOf(n.fills);
    const geometry = (n.geometry as N[]) ?? [];
    if (fill) {
      for (const g of geometry) out.push(`<path transform="matrix(${fmt(own)})" d="${g.d}" fill="${fill}"${g.winding === "evenodd" ? ' fill-rule="evenodd"' : ""}/>`);
      if (!geometry.length && (n.type === "rectangle" || n.type === "ellipse") && n !== root) {
        const [w, h] = (n.size as number[]) ?? [0, 0];
        out.push(n.type === "rectangle" ? `<rect transform="matrix(${fmt(own)})" width="${w}" height="${h}" fill="${fill}"/>` : `<ellipse transform="matrix(${fmt(own)})" cx="${w / 2}" cy="${h / 2}" rx="${w / 2}" ry="${h / 2}" fill="${fill}"/>`);
      }
    }
    const stroke = solidOf(n.strokes);
    const outline = ((n.stroke as N | undefined)?.outline as N[]) ?? [];
    if (stroke) for (const g of outline) out.push(`<path transform="matrix(${fmt(own)})" d="${g.d}" fill="${stroke}"/>`);
    for (const c of (n.children as N[]) ?? []) walk(c, own);
  };
  walk(root, [1, 0, 0, 1, 0, 0]);
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${size[0]} ${size[1]}" fill="none" aria-hidden="true">${out.join("")}</svg>`;
}

function matrixOf(attr: string | null): Aff {
  const m = /matrix\(([^)]+)\)/.exec(attr ?? "");
  if (!m) return [1, 0, 0, 1, 0, 0];
  const v = m[1].split(/[\s,]+/).filter(Boolean).map(Number);
  return v.length === 6 && v.every(Number.isFinite) ? (v as Aff) : [1, 0, 0, 1, 0, 0];
}

const solid = (hex: string) => [{ type: "solid", color: hex }];

/** The icon's SVG as Pubd vectors inside a `box` × `box` frame (id `id`), scaled to fit;
 * null when it is not SVG this can draw. */
export function pubdFromSvg(svg: string, id: string, box: number): N | null {
  let doc: Document;
  try {
    doc = new DOMParser().parseFromString(svg, "image/svg+xml");
  } catch {
    return null;
  }
  const root = doc.documentElement;
  if (!root || root.tagName.toLowerCase() !== "svg" || doc.querySelector("parsererror")) return null;
  const vb = (root.getAttribute("viewBox") ?? "0 0 24 24").split(/[\s,]+/).map(Number);
  const [vx, vy, vw, vh] = vb.length === 4 && vb.every(Number.isFinite) ? vb : [0, 0, 24, 24];
  const scale = box / Math.max(vw, vh, 1);
  const base: Aff = [scale, 0, 0, scale, -vx * scale + (box - vw * scale) / 2, -vy * scale + (box - vh * scale) / 2];
  const children: N[] = [];
  let k = 0;
  for (const el of Array.from(root.querySelectorAll("path, rect, ellipse, circle"))) {
    const fill = el.getAttribute("fill") ?? root.getAttribute("fill") ?? "#000000";
    const stroke = el.getAttribute("stroke") ?? root.getAttribute("stroke");
    const paint = fill !== "none" ? fill : stroke && stroke !== "none" ? stroke : "";
    if (!paint) continue;
    const color = paint === "currentColor" ? "#1a1a1c" : paint;
    let d = el.getAttribute("d") ?? "";
    const num = (a: string) => Number(el.getAttribute(a) ?? 0);
    if (el.tagName === "rect") d = `M${num("x")} ${num("y")}h${num("width")}v${num("height")}h${-num("width")}Z`;
    if (el.tagName === "ellipse" || el.tagName === "circle") {
      const cx = num("cx");
      const cy = num("cy");
      const rx = el.tagName === "circle" ? num("r") : num("rx");
      const ry = el.tagName === "circle" ? num("r") : num("ry");
      d = `M${cx - rx} ${cy}a${rx} ${ry} 0 1 0 ${2 * rx} 0a${rx} ${ry} 0 1 0 ${-2 * rx} 0Z`;
    }
    if (!d) continue;
    children.push({
      id: `${id}:p${k++}`,
      type: "vector",
      name: "path",
      transform: mul(base, matrixOf(el.getAttribute("transform"))),
      size: [vw, vh],
      fills: solid(color),
      geometry: [{ winding: el.getAttribute("fill-rule") === "evenodd" ? "evenodd" : "nonzero", d }],
    });
  }
  return { id, type: "frame", name: "icon", size: [box, box], clip: true, children };
}
