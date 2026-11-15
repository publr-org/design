// Resizing, rotating and scaling on the canvas, as Figma's selection box does:
// - corner handles and the box's edges resize (Shift keeps proportions, Alt resizes from
//   the centre); dragging past the opposite edge flips the layer;
// - several layers resize together as one box (each keeps its place in it);
// - just outside a corner the pointer rotates (Shift: steps of 15°);
// - with the scale tool (K) the same handles scale: proportions kept, and strokes,
//   effects, corner radii, auto layout spacing and text sizes scale too;
// - inside the layer, children follow their constraints and a vector's path is redrawn
//   at the new size (engine/src/edit/canvas.zig `resizePlan`); a hug or fill width or
//   height dragged becomes fixed, and auto width text becomes auto height (or fixed).
//
// Glue, not UI.

import { angleOf, apply, apply_, clean, corners, editing, engine, inv, mul, rotation, scaling, translate, turned, union, aabbOf } from "./geo";
import type { Aff, Box, Geo, Pt } from "./geo";
import { fmt, pill, BLUE } from "./marks";
import type { Painter } from "./marks";
import { drawGuides, SNAP_PX, snapBox, targetsIn } from "./snap";
import type { Snapped, Targets } from "./snap";
import type { Pointer } from "./move";

/** Which edges a handle moves: -1 the start (left, top), 1 the end, 0 neither. */
export type Handle = { hx: -1 | 0 | 1; hy: -1 | 0 | 1 };

/** The selection's frame on screen: one layer's own (maybe turned) box, or the box
 * around several. Its transform maps the box (0..w, 0..h) to the page. */
export type Frame = { ctm: Aff; size: [number, number] };

export function frameOf(sel: Geo[]): Frame | null {
  if (!sel.length) return null;
  if (sel.length === 1) return { ctm: sel[0].ctm, size: sel[0].size };
  const b = union(sel.map((g) => aabbOf(g.ctm, g.size)))!;
  return { ctm: [1, 0, 0, 1, b[0], b[1]], size: [b[2] - b[0], b[3] - b[1]] };
}

/** Where on the selection's frame screen point `s` is: a handle or edge, the rotation
 * ring just outside a corner, or nothing. */
export function zoneAt(p: Painter, f: Frame, s: Pt): { kind: "resize"; h: Handle } | { kind: "rotate"; corner: Pt } | null {
  const c = corners(f.ctm, f.size).map((q) => p.screen(q[0], q[1]));
  const hs: Handle[] = [
    { hx: -1, hy: -1 },
    { hx: 1, hy: -1 },
    { hx: 1, hy: 1 },
    { hx: -1, hy: 1 },
  ];
  const big = Math.hypot(c[1][0] - c[0][0], c[1][1] - c[0][1]) > 12 && Math.hypot(c[3][0] - c[0][0], c[3][1] - c[0][1]) > 12;
  for (let k = 0; k < 4; k++) if (Math.hypot(s[0] - c[k][0], s[1] - c[k][1]) <= 5) return { kind: "resize", h: hs[k] };
  // Edges: within 4 px of the line between two corners.
  const edges: [number, number, Handle][] = [
    [0, 1, { hx: 0, hy: -1 }],
    [1, 2, { hx: 1, hy: 0 }],
    [2, 3, { hx: 0, hy: 1 }],
    [3, 0, { hx: -1, hy: 0 }],
  ];
  if (big)
    for (const [a, b, h] of edges) {
      const ax = c[a][0];
      const ay = c[a][1];
      const dx = c[b][0] - ax;
      const dy = c[b][1] - ay;
      const len2 = dx * dx + dy * dy;
      const t = ((s[0] - ax) * dx + (s[1] - ay) * dy) / len2;
      if (t < 0 || t > 1) continue;
      if (Math.hypot(s[0] - (ax + t * dx), s[1] - (ay + t * dy)) <= 4) return { kind: "resize", h };
    }
  // The rotation ring: outside the box, 5..18 px from a corner.
  const inv_ = inv(f.ctm);
  for (let k = 0; k < 4; k++) {
    const d = Math.hypot(s[0] - c[k][0], s[1] - c[k][1]);
    if (d > 5 && d <= 18) {
      const [lx, ly] = apply(inv_, ...pageOf(p, s));
      const outside = lx < 0 || ly < 0 || lx > f.size[0] || ly > f.size[1];
      if (outside) return { kind: "rotate", corner: c[k] };
    }
  }
  return null;
}

function pageOf(p: Painter, s: Pt): Pt {
  // Two points give the screen-to-page mapping (the view is a scale and a shift).
  const [ox, oy] = p.screen(0, 0);
  const z = p.zoom();
  return [(s[0] - ox) / z, (s[1] - oy) / z];
}

/** The CSS cursor for a handle whose direction on screen is `angle` radians. */
export function resizeCursor(f: Frame, h: Handle): string {
  const [vx, vy] = [h.hx, h.hy];
  const m = f.ctm;
  const dir = Math.atan2(m[1] * vx + m[3] * vy, m[0] * vx + m[2] * vy);
  const deg = (((dir * 180) / Math.PI) % 180 + 180) % 180;
  if (deg < 22.5 || deg >= 157.5) return "ew-resize";
  if (deg < 67.5) return "nwse-resize";
  if (deg < 112.5) return "ns-resize";
  return "nesw-resize";
}

/** A curved double arrow, turned to face the corner it sits at. */
export function rotateCursor(angle: number): string {
  const svg = `<svg xmlns='http://www.w3.org/2000/svg' width='24' height='24' viewBox='0 0 24 24'><g transform='rotate(${Math.round((angle * 180) / Math.PI)} 12 12)'><path d='M7 15 A8 8 0 0 1 15 7' fill='none' stroke='white' stroke-width='4'/><path d='M7 15 A8 8 0 0 1 15 7' fill='none' stroke='black' stroke-width='1.5'/><path d='M4 13 L7 17 L10 13 Z M13 4 L17 7 L13 10 Z' fill='black' stroke='white' stroke-width='1'/></g></svg>`;
  return `url("data:image/svg+xml,${encodeURIComponent(svg)}") 12 12, crosshair`;
}

type Item = { g: Geo; text0: Geo["resize"]; first: boolean };

export class ResizeDrag {
  private sel: Item[];
  private f0: Frame;
  private h: Handle;
  private scale: boolean;
  private began = false;
  private targets: Targets;
  private snapped: Snapped = { dx: 0, dy: 0, xs: [], ys: [] };
  private label = "";
  private labelAt: Pt = [0, 0];
  private box: Box = [0, 0, 0, 0];

  constructor(sel: Geo[], h: Handle, scale: boolean) {
    this.sel = sel.map((g) => ({ g, text0: g.resize, first: true }));
    this.f0 = frameOf(sel)!;
    this.h = h;
    this.scale = scale;
    const ed = editing();
    if (!ed) throw new Error("no document open for editing");
    ed.begin();
    this.began = true;
    this.targets = targetsIn(sel[0].parent, new Set(sel.map((g) => g.id)));
  }

  move(p: Pointer, zoom: number): void {
    const f = this.f0;
    const [w0, h0] = f.size;
    const [lx, ly] = apply(inv(f.ctm), p.x, p.y);
    let L = 0;
    let R = w0;
    let T = 0;
    let B = h0;
    const { hx, hy } = this.h;
    if (hx === 1) R = lx;
    if (hx === -1) L = lx;
    if (hy === 1) B = ly;
    if (hy === -1) T = ly;
    // Snapping the moving edges (an unturned frame only), then whole pixels.
    const straight = !turned(f.ctm) && f.ctm[0] > 0 && f.ctm[3] > 0;
    if (straight) {
      const pageBox: Box = [f.ctm[4] + L * f.ctm[0], f.ctm[5] + T * f.ctm[3], f.ctm[4] + R * f.ctm[0], f.ctm[5] + B * f.ctm[3]];
      this.snapped = snapBox(pageBox, this.targets, SNAP_PX / zoom, hx === 1 ? [2] : hx === -1 ? [0] : [], hy === 1 ? [2] : hy === -1 ? [0] : []);
      const px = (v: number, s: number) => (Math.round(f.ctm[4] + v * f.ctm[0] + s) - f.ctm[4]) / f.ctm[0];
      const py = (v: number, s: number) => (Math.round(f.ctm[5] + v * f.ctm[3] + s) - f.ctm[5]) / f.ctm[3];
      if (hx === 1) R = px(R, this.snapped.dx);
      if (hx === -1) L = px(L, this.snapped.dx);
      if (hy === 1) B = py(B, this.snapped.dy);
      if (hy === -1) T = py(T, this.snapped.dy);
    }
    // Alt: from the centre (the opposite edge mirrors the moving one).
    if (p.alt) {
      if (hx === 1) L = w0 - R;
      if (hx === -1) R = w0 - L;
      if (hy === 1) T = h0 - B;
      if (hy === -1) B = h0 - T;
    }
    // Shift (and the scale tool): proportions kept.
    if (p.shift || this.scale) {
      const sx = w0 ? (R - L) / w0 : 1;
      const sy = h0 ? (B - T) / h0 : 1;
      if (hx && hy) {
        const s = Math.abs(sx) > Math.abs(sy) ? sx : sy;
        const kx = Math.sign(sx || 1) * Math.abs(s);
        const ky = Math.sign(sy || 1) * Math.abs(s);
        if (hx === 1) R = L + w0 * kx;
        else L = R - w0 * kx;
        if (hy === 1) B = T + h0 * ky;
        else T = B - h0 * ky;
        if (p.alt) {
          const cx = w0 / 2;
          const cy = h0 / 2;
          L = cx - (w0 * kx) / 2;
          R = cx + (w0 * kx) / 2;
          T = cy - (h0 * ky) / 2;
          B = cy + (h0 * ky) / 2;
        }
      } else if (hx) {
        const nh = h0 * Math.abs(sx);
        T = (h0 - nh) / 2;
        B = T + nh;
      } else if (hy) {
        const nw = w0 * Math.abs(sy);
        L = (w0 - nw) / 2;
        R = L + nw;
      }
    }
    // A line stays flat.
    if (h0 === 0) {
      T = 0;
      B = 0;
    }
    const fx = R < L ? -1 : 1;
    const fy = B < T ? -1 : 1;
    const nw = Math.abs(R - L);
    const nh = Math.abs(B - T);
    // The frame's new transform: the old one, moved to the new corner, flipped as dragged.
    const ctm1 = mul(f.ctm, mul(translate(L, T), scaling(fx, fy)));
    const changes: unknown[] = [];
    if (this.sel.length === 1) {
      const it = this.sel[0];
      changes.push(...this.first(it, hx !== 0, hy !== 0));
      changes.push({ op: "set", node: it.g.id, props: { transform: clean(mul(inv(it.g.pctm), ctm1)) } });
      changes.push(...engine()!.canvasResize(it.g.id, Math.max(nw, 0.01), h0 === 0 ? 0 : Math.max(nh, 0.01), this.scale));
    } else {
      // Every layer keeps its place in the box: the box's change applied to its corner,
      // its size scaled on each axis.
      const sx = w0 ? (R - L) / w0 : 1;
      const sy = h0 ? (B - T) / h0 : 1;
      const map = mul(f.ctm, mul(translate(L, T), mul(scaling(sx, sy), inv(f.ctm))));
      for (const it of this.sel) {
        const g = it.g;
        changes.push(...this.first(it, hx !== 0, hy !== 0));
        const flip = scaling(sx < 0 ? -1 : 1, sy < 0 ? -1 : 1);
        const origin = apply(map, g.ctm[4], g.ctm[5]);
        const lin = turned(g.ctm) ? g.ctm : mul([g.ctm[0], g.ctm[1], g.ctm[2], g.ctm[3], 0, 0], flip);
        const ctm: Aff = [lin[0], lin[1], lin[2], lin[3], origin[0], origin[1]];
        const k = this.scale || turned(g.ctm) ? Math.abs(Math.abs(sx) > Math.abs(sy) ? sx : sy) : 0;
        const w = k ? g.size[0] * k : g.size[0] * Math.abs(sx);
        const h = k ? g.size[1] * k : g.size[1] * Math.abs(sy);
        changes.push({ op: "set", node: g.id, props: { transform: clean(mul(inv(g.pctm), ctm)) } });
        changes.push(...engine()!.canvasResize(g.id, Math.max(w, 0.01), g.size[1] === 0 ? 0 : Math.max(h, 0.01), this.scale));
      }
    }
    apply_(changes);
    const c = corners(ctm1, [nw, nh]);
    this.box = [Math.min(...c.map((q) => q[0])), Math.min(...c.map((q) => q[1])), Math.max(...c.map((q) => q[0])), Math.max(...c.map((q) => q[1]))];
    this.label = "";
    void zoom;
  }

  /** What the first move switches: auto width text to auto height or fixed; a hug or
   * fill size on a dragged axis to fixed. */
  private first(it: Item, xs: boolean, ys: boolean): unknown[] {
    if (!it.first) return [];
    it.first = false;
    const g = it.g;
    const props: Record<string, unknown> = {};
    if (g.type === "text" && !this.scale) {
      if (g.resize === "width-and-height") props.resize = ys ? "fixed" : "height";
      else if (g.resize === "height" && ys) props.resize = "fixed";
    }
    if (g.playout && !g.absolute) {
      const [w, h] = g.sizing;
      if ((xs && w !== "fixed") || (ys && h !== "fixed")) props.sizing = { w: xs ? "fixed" : w, h: ys ? "fixed" : h };
    }
    if (g.layout && ((xs && g.layout.width === "hug") || (ys && g.layout.height === "hug"))) {
      const full = engine()!.nodeInfo(g.id).node.layout as Record<string, unknown>;
      props.layout = { ...full, ...(xs ? { width: "fixed" } : {}), ...(ys ? { height: "fixed" } : {}) };
    }
    return Object.keys(props).length ? [{ op: "set", node: g.id, props }] : [];
  }

  draw(p: Painter): void {
    drawGuides(p, this.box, this.targets, this.snapped);
    void this.label;
    void this.labelAt;
  }

  up(): void {
    this.end(false);
  }

  cancel(): void {
    this.end(true);
  }

  private end(cancel: boolean): void {
    if (!this.began) return;
    this.began = false;
    const ed = editing();
    if (cancel) ed?.cancel();
    else ed?.commit();
  }
}

export class RotateDrag {
  private sel: Geo[];
  private pivot: Pt;
  private a0: number;
  private began = false;
  private angle = 0;
  private at: Pt = [0, 0];

  constructor(sel: Geo[], start: Pt) {
    this.sel = sel;
    const f = frameOf(sel)!;
    this.pivot = apply(f.ctm, f.size[0] / 2, f.size[1] / 2);
    this.a0 = Math.atan2(start[1] - this.pivot[1], start[0] - this.pivot[0]);
    const ed = editing();
    if (!ed) throw new Error("no document open for editing");
    ed.begin();
    this.began = true;
  }

  move(p: Pointer): void {
    let d = Math.atan2(p.y - this.pivot[1], p.x - this.pivot[0]) - this.a0;
    const base = angleOf(this.sel[0].ctm);
    if (p.shift) {
      const step = Math.PI / 12;
      d = Math.round((base + d) / step) * step - base;
    }
    const r = mul(translate(this.pivot[0], this.pivot[1]), mul(rotation(d), translate(-this.pivot[0], -this.pivot[1])));
    const changes = this.sel.map((g) => ({ op: "set", node: g.id, props: { transform: clean(mul(inv(g.pctm), mul(r, g.ctm))) } }));
    apply_(changes);
    // Figma counts angles anticlockwise, in whole degrees shown.
    let deg = (-(base + d) * 180) / Math.PI;
    deg = ((deg % 360) + 540) % 360 - 180;
    this.angle = deg;
    this.at = [p.x, p.y];
  }

  draw(p: Painter): void {
    const [x, y] = p.screen(this.at[0], this.at[1]);
    pill(p, `${fmt(Math.round(this.angle * 10) / 10)}°`, x + 28, y + 24, BLUE);
  }

  up(): void {
    this.end(false);
  }

  cancel(): void {
    this.end(true);
  }

  private end(cancel: boolean): void {
    if (!this.began) return;
    this.began = false;
    const ed = editing();
    if (cancel) ed?.cancel();
    else ed?.commit();
  }
}
