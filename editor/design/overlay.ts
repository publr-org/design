// The editor's marks over the canvas, on a canvas of their own above the viewer's: frame
// names above top-level frames, layout guides, the rulers, and what the canvas's tools
// draw (tools/canvas.ts: hover, the selection with its handles, guides, distances, the
// text caret). Redrawn after every frame the stage draws (the camera moved) and whenever
// the selection, the hover or a tool's marks change; never makes the page draw again.
//
// The pointer and the keys on the canvas go to the tools; the Hand tool and Space drag
// the view (the stage pans).

import type { Stage } from "../viewer/stage";
import { aabb, F, typeOf } from "./doc";
import type { Tree } from "./doc";
import { currentTree, setHover, shell } from "./store";
import { geo } from "./tools/geo";
import type { Painter } from "./tools/marks";
import { Tools } from "./tools/canvas";

/** Colours of the marks (the editor's, not the theme's: they sit on the page). */
const BLUE = "#0d99ff";
const PURPLE = "#9747ff";
const RULER = 20;
/** Top-level layers named above their corner. */
const ARTBOARD_KINDS = new Set(["frame", "component", "component-set", "section", "instance"]);

export class Overlay {
  canvas: HTMLCanvasElement;
  private ctx: CanvasRenderingContext2D;
  stage: Stage;
  private dpr = 1;
  private spaceDown = false;
  private scheduled = false;
  /** What the pointer and keys do on the canvas, and the marks they draw. */
  readonly tools: Tools;

  constructor(host: HTMLElement, stage: Stage) {
    this.stage = stage;
    this.canvas = document.createElement("canvas");
    this.canvas.dataset.pdOverlay = "";
    this.canvas.style.cssText = "position:absolute;inset:0;width:100%;height:100%;display:block;pointer-events:none";
    host.append(this.canvas);
    const ctx = this.canvas.getContext("2d");
    if (!ctx) throw new Error("no 2d canvas");
    this.ctx = ctx;
    this.tools = new Tools({
      painter: () => this.painter(),
      toPage: (sx, sy) => this.toPage(sx, sy),
      request: () => this.request(),
      canvas: stage.canvas,
      spaceDown: () => this.spaceDown,
    });
    new ResizeObserver(() => this.resize()).observe(this.canvas);
    this.resize();
    stage.chrome = () => this.draw();
    this.listen(host);
  }

  /** What the tools draw with. */
  painter(): Painter {
    return { ctx: this.ctx, dpr: this.dpr, screen: (x, y) => this.toScreen(x, y), zoom: () => this.view().z };
  }

  private resize(): void {
    this.dpr = window.devicePixelRatio || 1;
    const r = this.canvas.getBoundingClientRect();
    this.canvas.width = Math.max(1, Math.round(r.width * this.dpr));
    this.canvas.height = Math.max(1, Math.round(r.height * this.dpr));
    this.draw();
  }

  /** Redraws on the next animation frame (marks changed, the view did not). */
  request(): void {
    if (this.scheduled) return;
    this.scheduled = true;
    requestAnimationFrame(() => {
      this.scheduled = false;
      this.draw();
    });
  }

  /** The camera as the stage draws it: moved to whole device pixels. */
  private view(): { x: number; y: number; z: number } {
    const c = this.stage.cam;
    const dev = c.z * this.dpr;
    return { x: Math.round(c.x * dev) / dev, y: Math.round(c.y * dev) / dev, z: c.z };
  }

  /** Page point to CSS pixel. */
  private toScreen(px: number, py: number): [number, number] {
    const v = this.view();
    return [(px - v.x) * v.z, (py - v.y) * v.z];
  }

  /** CSS pixel to page point. */
  toPage(sx: number, sy: number): [number, number] {
    const v = this.view();
    return [v.x + sx / v.z, v.y + sy / v.z];
  }

  draw(): void {
    const ctx = this.ctx;
    const d = this.dpr;
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.clearRect(0, 0, this.canvas.width, this.canvas.height);
    ctx.setTransform(d, 0, 0, d, 0, 0);
    const t = currentTree();
    // While a page switch waits, the old page shows veiled under the rulers alone.
    if (this.stage.doc && !this.stage.isSwitching()) {
      if (shell.guides && t.n) this.drawGrids(t);
      this.drawNames();
      try {
        this.tools.draw(this.painter());
      } catch (err) {
        console.error("canvas marks", err);
      }
    }
    if (shell.rulers) this.drawRulers();
  }

  /** Layout guides of the frames in view: columns, rows and square grids, in their
   * own colours, over the content as the editor draws them. */
  private drawGrids(t: Tree): void {
    const ctx = this.ctx;
    const W = this.canvas.width / this.dpr;
    const H = this.canvas.height / this.dpr;
    const z = this.view().z;
    for (const [i, list] of t.grids) {
      if (!(t.flags[i] & F.visible) || t.flags[i] & F.hiddenAbove) continue;
      const m = t.xf.subarray(i * 6, i * 6 + 6);
      const w = t.size[i * 2];
      const h = t.size[i * 2 + 1];
      const b = aabb(t, i);
      const [x0, y0] = this.toScreen(b[0], b[1]);
      const [x1, y1] = this.toScreen(b[2], b[3]);
      if (x1 < 0 || y1 < 0 || x0 > W || y0 > H) continue;
      ctx.save();
      // Node space to device pixels; clipped by every clipping frame around it.
      const v = this.view();
      const d = this.dpr;
      const place = (k: number) => {
        const a = t.xf.subarray(k * 6, k * 6 + 6);
        ctx.setTransform(a[0] * z * d, a[1] * z * d, a[2] * z * d, a[3] * z * d, (a[4] - v.x) * z * d, (a[5] - v.y) * z * d);
        ctx.beginPath();
        ctx.rect(0, 0, t.size[k * 2], t.size[k * 2 + 1]);
        ctx.clip();
      };
      for (let p = t.parent[i]; p >= 0; p = t.parent[p]) if (t.flags[p] & F.clip && typeOf(t, p) !== "group") place(p);
      place(i);
      void m;
      for (const g of list) {
        if (g.visible === false) continue;
        ctx.fillStyle = gridColor(g.color);
        ctx.strokeStyle = ctx.fillStyle;
        if (g.type === "grid") {
          const step = g.size ?? 10;
          if (step * z < 4) continue;
          ctx.lineWidth = 1 / z;
          ctx.beginPath();
          for (let x = step; x < w; x += step) {
            ctx.moveTo(x, 0);
            ctx.lineTo(x, h);
          }
          for (let y = step; y < h; y += step) {
            ctx.moveTo(0, y);
            ctx.lineTo(w, y);
          }
          ctx.stroke();
          continue;
        }
        const across = g.type === "rows" ? h : w;
        const count = Math.max(1, g.count ?? 1);
        const gutter = g.gutter ?? 0;
        const offset = g.offset ?? 0;
        const stretch = (g.align ?? "stretch") === "stretch";
        const size = stretch ? (across - offset * 2 - gutter * (count - 1)) / count : (g.size ?? 0);
        const total = size * count + gutter * (count - 1);
        const start = stretch || g.align === "start" ? offset : g.align === "end" ? across - offset - total : (across - total) / 2 + offset;
        for (let k = 0; k < count; k++) {
          const a = start + k * (size + gutter);
          if (g.type === "rows") ctx.fillRect(0, a, w, size);
          else ctx.fillRect(a, 0, size, h);
        }
      }
      ctx.restore();
    }
  }

  /** Top-level frames' names, above their top-left corners (blue when selected), from
   * the engine's page list (it follows edits). */
  private drawNames(): void {
    const ctx = this.ctx;
    // The names sit on the page: dark on a light page, light on a dark one (by the
    // page colour's luminance, in linear light: Figma's names are light on #929292).
    const pg = this.stage.currentPage();
    const bg = pg?.background ?? [0.96, 0.96, 0.96];
    const lin = (c: number) => (c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4);
    const dark = 0.2126 * lin(bg[0]) + 0.7152 * lin(bg[1]) + 0.0722 * lin(bg[2]) < 0.5;
    const sel = new Set(shell.selection);
    ctx.font = `500 11px "PD Inter", Inter, system-ui, sans-serif`;
    ctx.textBaseline = "alphabetic";
    for (const f of pg?.frames ?? []) {
      if (!ARTBOARD_KINDS.has(f.type)) continue;
      this.nameOf(f.box, f.name || f.type, f.type, sel.has(f.id) || shell.hover === f.id, dark);
    }
  }

  /** A top-level node's name above its top left corner, cut to the node's width with an
   * ellipsis as Figma does ("Collections-…", "C…"), and left out when not even one
   * letter and the ellipsis fit. Components and instances carry their mark, in purple. */
  private nameOf(b: number[], name: string, type: string, on: boolean, dark: boolean): void {
    const ctx = this.ctx;
    const [x0, y0] = this.toScreen(b[0], b[1]);
    const [x1] = this.toScreen(b[2], b[3]);
    const w = x1 - x0;
    if (y0 < -4 || x0 > this.canvas.width / this.dpr || x1 < 0) return;
    const purple = type === "component" || type === "component-set" || type === "instance";
    const mark = purple ? 13 : 0;
    // A component keeps its mark and an ellipsis when no letter fits (Figma's "❖ …").
    const label = fitName(ctx, name, w - mark - 4) || (purple && w >= mark + 10 ? "\u2026" : "");
    if (!label) return;
    ctx.fillStyle = on ? (purple ? PURPLE : BLUE) : purple ? PURPLE : dark ? "rgba(255,255,255,0.7)" : "rgba(0,0,0,0.5)";
    ctx.strokeStyle = ctx.fillStyle;
    const y = Math.round(y0 - 6);
    const x = Math.round(x0);
    if (purple) {
      // The component's small diamond before the name.
      ctx.save();
      ctx.lineWidth = 1;
      ctx.translate(x + 0.5, y - 8.5);
      ctx.beginPath();
      ctx.moveTo(4, 0);
      ctx.lineTo(8, 4);
      ctx.lineTo(4, 8);
      ctx.lineTo(0, 4);
      ctx.closePath();
      ctx.stroke();
      ctx.restore();
    }
    ctx.fillText(label, x + mark, y);
  }

  /** Rulers along the top and the left, the selection's extent marked on them. */
  private drawRulers(): void {
    const ctx = this.ctx;
    const W = this.canvas.width / this.dpr;
    const H = this.canvas.height / this.dpr;
    const css = getComputedStyle(document.documentElement);
    const bg = css.getPropertyValue("--pd-ruler").trim() || "#2c2c2c";
    const fg = css.getPropertyValue("--pd-ruler-text").trim() || "rgba(255,255,255,0.5)";
    const mark = css.getPropertyValue("--pd-ruler-select").trim() || "#394360";
    const line = css.getPropertyValue("--pd-border").trim() || "#444";
    ctx.fillStyle = bg;
    ctx.fillRect(0, 0, W, RULER);
    ctx.fillRect(0, 0, RULER, H);
    const box = this.stage.doc ? this.tools.selectionBox() : null;
    // With a selection, the rulers count from the corner of the frame it is in (a
    // top-level one: its own), as the editor's do; otherwise from the page's origin.
    let ox = 0;
    let oy = 0;
    const first = shell.selection[0] ? geo(shell.selection[0]) : null;
    if (first) {
      const p = first.parent && first.ptype !== "page" ? geo(first.parent) : null;
      const m = p ? p.ctm : first.ctm;
      ox = m[4];
      oy = m[5];
    }
    const v = this.view();
    if (box) {
      const [x0, y0] = this.toScreen(box[0], box[1]);
      const [x1, y1] = this.toScreen(box[2], box[3]);
      ctx.fillStyle = mark;
      ctx.fillRect(Math.max(RULER, x0), 0, Math.max(0, x1 - Math.max(RULER, x0)), RULER);
      ctx.fillRect(0, Math.max(RULER, y0), RULER, Math.max(0, y1 - Math.max(RULER, y0)));
    }
    // A step that keeps labels at least ~50 px apart: 1, 2, 5 x 10^n page units.
    const raw = 50 / v.z;
    const p = 10 ** Math.floor(Math.log10(raw));
    const step = raw / p <= 1 ? p : raw / p <= 2 ? 2 * p : raw / p <= 5 ? 5 * p : 10 * p;
    ctx.font = `450 9px "PD Inter", Inter, system-ui, sans-serif`;
    ctx.fillStyle = fg;
    ctx.strokeStyle = fg;
    ctx.lineWidth = 1;
    ctx.textBaseline = "alphabetic";
    // The selection's edges are labelled on the rulers; numbers near them give way.
    const sx: number[] = [];
    const sy: number[] = [];
    if (box) {
      const [a, b] = this.toScreen(box[0], box[1]);
      const [c, d] = this.toScreen(box[2], box[3]);
      sx.push(a, c);
      sy.push(b, d);
    }
    const clear = (p: number, marks: number[]) => marks.every((m) => Math.abs(p - m) > 34);
    ctx.textAlign = "center";
    ctx.beginPath();
    for (let u = Math.floor((v.x - ox) / step) * step; u <= v.x - ox + W / v.z; u += step) {
      const x = Math.round((u + ox - v.x) * v.z) + 0.5;
      if (x < RULER) continue;
      ctx.moveTo(x, RULER - 4);
      ctx.lineTo(x, RULER);
      if (clear(x, sx)) ctx.fillText(fmt(u), x, 11);
    }
    for (let u = Math.floor((v.y - oy) / step) * step; u <= v.y - oy + H / v.z; u += step) {
      const y = Math.round((u + oy - v.y) * v.z) + 0.5;
      if (y < RULER) continue;
      ctx.moveTo(RULER - 4, y);
      ctx.lineTo(RULER, y);
      if (!clear(y, sy)) continue;
      ctx.save();
      ctx.translate(11, y);
      ctx.rotate(-Math.PI / 2);
      ctx.fillText(fmt(u), 0, 0);
      ctx.restore();
    }
    ctx.textAlign = "start";
    ctx.stroke();
    if (box) {
      ctx.fillStyle = BLUE;
      ctx.font = `500 9px "PD Inter", Inter, system-ui, sans-serif`;
      const [x0, y0] = this.toScreen(box[0], box[1]);
      const [x1, y1] = this.toScreen(box[2], box[3]);
      for (const [x, label] of [
        [x0, fmt(box[0] - ox)],
        [x1, fmt(box[2] - ox)],
      ] as [number, string][]) {
        if (x < RULER) continue;
        ctx.fillStyle = mark;
        const tw = ctx.measureText(label).width;
        ctx.fillRect(x - tw / 2 - 2, 2, tw + 4, 14);
        ctx.fillStyle = BLUE;
        ctx.fillText(label, x - tw / 2, 12);
      }
      for (const [y, label] of [
        [y0, fmt(box[1] - oy)],
        [y1, fmt(box[3] - oy)],
      ] as [number, string][]) {
        if (y < RULER) continue;
        ctx.save();
        ctx.translate(12, y);
        ctx.rotate(-Math.PI / 2);
        const tw = ctx.measureText(label).width;
        ctx.fillStyle = mark;
        ctx.fillRect(-tw / 2 - 2, -10, tw + 4, 14);
        ctx.fillStyle = BLUE;
        ctx.fillText(label, -tw / 2, 0);
        ctx.restore();
      }
    }
    ctx.fillStyle = bg;
    ctx.fillRect(0, 0, RULER, RULER);
    ctx.fillStyle = line;
    ctx.fillRect(0, RULER - 0.5, W, 0.5);
    ctx.fillRect(RULER - 0.5, 0, 0.5, H);
  }

  // ------------------------------------------------------------ the pointer

  private listen(host: HTMLElement): void {
    const onCanvas = (e: Event) => e.target === this.stage.canvas;
    host.addEventListener(
      "pointerdown",
      (e: PointerEvent) => {
        if (!onCanvas(e) || e.button !== 0 || this.spaceDown || shell.tool === "hand") return;
        if (this.tools.down(e)) this.request();
      },
      true,
    );
    // In a text edit, a press on the canvas must not take focus from the text's input
    // (that would end the edit before the press places the caret or selects).
    host.addEventListener("mousedown", (e: MouseEvent) => {
      if (onCanvas(e) && this.tools.text) e.preventDefault();
    });
    host.addEventListener("pointermove", (e: PointerEvent) => {
      if (onCanvas(e)) this.tools.hover(e);
    });
    host.addEventListener("pointerleave", () => setHover(""));
    host.addEventListener("dblclick", (e: MouseEvent) => {
      if (onCanvas(e)) this.tools.dblclick(e);
    });
    // Before the shell's keys: Esc during a drag cancels only the drag.
    window.addEventListener(
      "keydown",
      (e: KeyboardEvent) => {
        if (e.code === "Space") this.spaceDown = true;
        this.tools.key(e);
      },
      true,
    );
    window.addEventListener("keyup", (e: KeyboardEvent) => {
      if (e.code === "Space") this.spaceDown = false;
      this.tools.keyUp(e);
    });
    window.addEventListener("blur", () => (this.spaceDown = false));
  }
}

/** A guide's colour: Pubd hex or [r, g, b, a] (the default a faint red). */
function gridColor(c: unknown): string {
  if (typeof c === "string") return c;
  if (Array.isArray(c)) return `rgba(${Math.round(c[0] * 255)},${Math.round(c[1] * 255)},${Math.round(c[2] * 255)},${c[3] ?? 1})`;
  return "rgba(255,0,0,0.1)";
}

const fmt = (v: number) => {
  const r = Math.round(v * 100) / 100;
  return String(Object.is(r, -0) ? 0 : r);
};

/** `name` as it fits in `room` pixels in the context's font: whole, or cut with an
 * ellipsis (at least one letter); "" when even that does not fit. */
const fitted = new Map<string, string>();

function fitName(ctx: CanvasRenderingContext2D, name: string, room: number): string {
  if (room <= 0) return "";
  // Names keep their cut while the zoom stays (one entry per name and whole pixel).
  const key = `${Math.floor(room)}|${name}`;
  const known = fitted.get(key);
  if (known !== undefined) return known;
  if (fitted.size > 4000) fitted.clear();
  const out = cutName(ctx, name, Math.floor(room));
  fitted.set(key, out);
  return out;
}

function cutName(ctx: CanvasRenderingContext2D, name: string, room: number): string {
  if (ctx.measureText(name).width <= room) return name;
  const chars = Array.from(name);
  // The longest start that fits with the ellipsis (binary search over letters).
  let lo = 0;
  let hi = chars.length - 1;
  while (lo < hi) {
    const mid = (lo + hi + 1) >> 1;
    if (ctx.measureText(chars.slice(0, mid).join("").trimEnd() + "\u2026").width <= room) lo = mid;
    else hi = mid - 1;
  }
  if (lo === 0) return "";
  return chars.slice(0, lo).join("").trimEnd() + "\u2026";
}
