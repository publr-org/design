// Drawing the tools' marks on the overlay canvas: the selection box with its handles,
// smart guides and red distance labels, the auto layout insertion line, the marquee,
// size and angle labels. CSS pixels; the overlay maps page points for us.
//
// Glue, not UI.

import type { Box, Pt } from "./geo";

export const BLUE = "#0d99ff";
export const PURPLE = "#9747ff";
/** Smart guides and measurements. */
export const RED = "#f24822";
/** Auto layout's insertion line and spacing. */
export const PINK = "#f22c8d";

/** What the tools draw with: the overlay's 2D context and its page-to-screen mapping. */
export interface Painter {
  ctx: CanvasRenderingContext2D;
  dpr: number;
  /** Page point to CSS pixel. */
  screen(x: number, y: number): Pt;
  /** CSS pixels per page unit (the zoom). */
  zoom(): number;
}

/** A page point at the centre of the device pixel it falls in. */
export function crisp(p: Painter, x: number, y: number): Pt {
  const [sx, sy] = p.screen(x, y);
  return [Math.round(sx * p.dpr) / p.dpr + 0.5 / p.dpr, Math.round(sy * p.dpr) / p.dpr + 0.5 / p.dpr];
}

export function polygon(p: Painter, pts: Pt[], color: string, width = 1): void {
  const ctx = p.ctx;
  ctx.beginPath();
  pts.forEach((pt, k) => {
    const [x, y] = crisp(p, pt[0], pt[1]);
    if (k) ctx.lineTo(x, y);
    else ctx.moveTo(x, y);
  });
  ctx.closePath();
  ctx.strokeStyle = color;
  ctx.lineWidth = width;
  ctx.stroke();
}

/** A line between two page points. */
export function line(p: Painter, a: Pt, b: Pt, color: string, width = 1, dash: number[] = []): void {
  const ctx = p.ctx;
  const [x0, y0] = crisp(p, a[0], a[1]);
  const [x1, y1] = crisp(p, b[0], b[1]);
  ctx.save();
  ctx.setLineDash(dash);
  ctx.beginPath();
  ctx.moveTo(x0, y0);
  ctx.lineTo(x1, y1);
  ctx.strokeStyle = color;
  ctx.lineWidth = width;
  ctx.stroke();
  ctx.restore();
}

/** A small label in a pill of `color`, centred on CSS point (x, y). */
export function pill(p: Painter, text: string, x: number, y: number, color: string): void {
  const ctx = p.ctx;
  ctx.font = `500 11px "PD Inter", Inter, system-ui, sans-serif`;
  const w = Math.ceil(ctx.measureText(text).width) + 8;
  const h = 16;
  const px = Math.round(x - w / 2);
  const py = Math.round(y - h / 2);
  ctx.fillStyle = color;
  ctx.beginPath();
  ctx.roundRect(px, py, w, h, 2);
  ctx.fill();
  ctx.fillStyle = "#ffffff";
  ctx.textBaseline = "middle";
  ctx.textAlign = "left";
  ctx.fillText(text, px + 4, py + 8.5);
}

/** A handle: a 7 px square, white with `color` around (screen point). */
export function handle(p: Painter, at: Pt, color: string): void {
  const ctx = p.ctx;
  const [x, y] = crisp(p, at[0], at[1]);
  ctx.fillStyle = "#ffffff";
  ctx.strokeStyle = color;
  ctx.lineWidth = 1;
  ctx.fillRect(x - 3.5, y - 3.5, 7, 7);
  ctx.strokeRect(x - 3.5, y - 3.5, 7, 7);
}

export const fmt = (v: number) => {
  const r = Math.round(v * 100) / 100;
  return String(Object.is(r, -0) ? 0 : r);
};

/** A measurement: a red line from `a` to `b` with its length in a red pill. */
export function measure(p: Painter, a: Pt, b: Pt): void {
  const len = Math.hypot(b[0] - a[0], b[1] - a[1]);
  if (len < 0.01) return;
  line(p, a, b, RED);
  const [x0, y0] = p.screen(a[0], a[1]);
  const [x1, y1] = p.screen(b[0], b[1]);
  // Ends: short ticks across the line.
  const horiz = Math.abs(y1 - y0) < Math.abs(x1 - x0);
  const ctx = p.ctx;
  ctx.strokeStyle = RED;
  ctx.lineWidth = 1;
  ctx.beginPath();
  for (const [x, y] of [
    [x0, y0],
    [x1, y1],
  ]) {
    const cx = Math.round(x) + 0.5;
    const cy = Math.round(y) + 0.5;
    if (horiz) {
      ctx.moveTo(cx, cy - 3);
      ctx.lineTo(cx, cy + 3);
    } else {
      ctx.moveTo(cx - 3, cy);
      ctx.lineTo(cx + 3, cy);
    }
  }
  ctx.stroke();
  const mx = (x0 + x1) / 2;
  const my = (y0 + y1) / 2;
  pill(p, fmt(len), horiz ? mx : mx + 18, horiz ? my + 14 : my, RED);
}

/** Red measurements between box `s` (the selection) and box `o`: to its edges when one
 * holds the other, else across the gap on each axis where they are apart. */
export function distances(p: Painter, s: Box, o: Box): void {
  const contains = (a: Box, b: Box) => a[0] <= b[0] && a[1] <= b[1] && a[2] >= b[2] && a[3] >= b[3];
  const cy = (s[1] + s[3]) / 2;
  const cx = (s[0] + s[2]) / 2;
  if (contains(o, s) || contains(s, o)) {
    const [inner, outer] = contains(o, s) ? [s, o] : [o, s];
    const iy = (inner[1] + inner[3]) / 2;
    const ix = (inner[0] + inner[2]) / 2;
    measure(p, [outer[0], iy], [inner[0], iy]);
    measure(p, [inner[2], iy], [outer[2], iy]);
    measure(p, [ix, outer[1]], [ix, inner[1]]);
    measure(p, [ix, inner[3]], [ix, outer[3]]);
    return;
  }
  // Apart horizontally: the gap at the middle of their vertical overlap (or the
  // selection's middle, with a dashed guide to the other box).
  if (o[2] < s[0] || o[0] > s[2]) {
    const y = Math.max(s[1], o[1]) <= Math.min(s[3], o[3]) ? (Math.max(s[1], o[1]) + Math.min(s[3], o[3])) / 2 : cy;
    const [a, b] = o[2] < s[0] ? [o[2], s[0]] : [s[2], o[0]];
    measure(p, [a, y], [b, y]);
    if (y < o[1] || y > o[3]) line(p, [o[2] < s[0] ? o[2] : o[0], y], [o[2] < s[0] ? o[2] : o[0], y < o[1] ? o[1] : o[3]], RED, 1, [3, 3]);
  }
  if (o[3] < s[1] || o[1] > s[3]) {
    const x = Math.max(s[0], o[0]) <= Math.min(s[2], o[2]) ? (Math.max(s[0], o[0]) + Math.min(s[2], o[2])) / 2 : cx;
    const [a, b] = o[3] < s[1] ? [o[3], s[1]] : [s[3], o[1]];
    measure(p, [x, a], [x, b]);
    if (x < o[0] || x > o[2]) line(p, [x, o[3] < s[1] ? o[3] : o[1]], [x < o[0] ? o[0] : o[2], o[3] < s[1] ? o[3] : o[1]], RED, 1, [3, 3]);
  }
}
