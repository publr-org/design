// Content mode's canvas: the page's frames on a world the camera moves (pan by wheel, the
// trackpad, Space-drag, the Hand tool or the middle button; zoom by pinch, Cmd+wheel,
// Cmd+= and Cmd+-), the overlay over it drawing what Design mode draws (hover, the
// selection box and its size, the marquee, the names above the frames), and the tools:
// only the content's bound, editable elements hover and select. Click selects a block,
// double-click goes into it (a text starts editing with all of it selected, an image asks
// for a file), Esc goes back up, Shift adds. Text is edited in place in its frame, with
// Figma's selection rules: a click places the caret, a double-click selects a word and a
// triple-click a line, dragging after either extends by words or lines.
//
// The camera scales the frames with a transform: while it moves the page is one layer the
// compositor moves (`will-change`); once it settles the layer is dropped, so the browser
// draws the text again at the new scale and it is sharp.
//
// Glue between the DOM adapter (frames.ts), the history and the chrome's store, not UI.

import { downcast, upcastBlocks } from "../../../editor/model/codec";
import { getPattern } from "../../../editor/model/patterns";
import { blockType } from "../../../editor/model/registry";
import { BLUE, crisp, pill } from "../design/tools/marks";
import type { Painter } from "../design/tools/marks";
import { DEVICES, FREE_MAX, FREE_MIN, breakpointAt, deviceOf, frameName, freeDevice } from "./breakpoints";
import type { DeviceKey } from "./breakpoints";
import type { PageSource } from "./documents";
import { Frame, GAP, readInfo, serialize } from "./frames";
import type { BlockInfo, Box, FieldInfo, Format } from "./frames";
import { History } from "./history";
import type { Snap, Step, Value } from "./history";
import { lineAt, offsetAtPoint, selectOffsets, selectionOffsets, textOf, wordAt } from "./text";
import { saveViewPref, view } from "./store";
import type { FieldRow, LayerRow } from "./store";

const MIN_ZOOM = 0.05;
const MAX_ZOOM = 8;
/** Room around the frames when they are fitted, CSS px (the top leaves the names room). */
const PAD_X = 48;
const PAD_TOP = 56;

type Camera = { x: number; y: number; z: number };
type Hit = { key: string; frame: number };
type Edit = { frame: Frame; key: string; el: HTMLElement; info: FieldInfo; session: number; islands: Element[] };
type Gesture =
  | { kind: "pan"; x: number; y: number }
  | { kind: "marquee"; x0: number; y0: number; x1: number; y1: number; base: string[]; scope: string; on: boolean }
  | { kind: "text"; anchor: [number, number]; grain: "char" | "word" | "line" }
  | { kind: "press"; x: number; y: number }
  | { kind: "resize"; side: 1 | -1; x: number; w: number };

const clamp = (v: number, a: number, b: number) => Math.min(b, Math.max(a, v));
const isBlock = (key: string) => key.startsWith("b");
const blockOf = (key: string) => (isBlock(key) ? key : `b${key.slice(1, key.indexOf("-"))}`);

const FORMAT_INPUT: Record<string, Format> = {
  formatBold: "bold",
  formatItalic: "italic",
  formatUnderline: "underline",
  formatStrikeThrough: "strikethrough",
  formatSubscript: "subscript",
  formatSuperscript: "superscript",
};

export class ContentCanvas {
  readonly host: HTMLElement;
  private world: HTMLElement;
  private overlay: HTMLCanvasElement;
  private ctx: CanvasRenderingContext2D;
  private dpr = 1;
  cam: Camera = { x: 0, y: 0, z: 1 };
  frames: Frame[] = [];
  private page: PageSource | null = null;
  /** The content as last copied out of the frames (rebuilt from on a breakpoint switch). */
  private content = "";
  blocks = new Map<string, BlockInfo>();
  fields = new Map<string, FieldInfo>();
  selection: string[] = [];
  private hover: Hit | null = null;
  /** The frame the last press was in: the selection's size shows there. */
  private active = 0;
  history = new History();
  edit: Edit | null = null;
  private sessions = 0;
  private gesture: Gesture | null = null;
  private spaceDown = false;
  private scheduled = false;
  private camDirty = false;
  private settle = 0;
  private pending: { html: string; caret: [number, number] | null } | null = null;
  private muted = false;
  private building = 0;
  /** Asks the chrome for an image file for field `key`. */
  onPickImage: ((key: string) => void) | null = null;
  /** Frame times while the camera moves (`?perf`). */
  perf: number[] = [];
  private lastFrame = 0;
  private disposers: (() => void)[] = [];

  constructor(host: HTMLElement) {
    this.host = host;
    this.world = document.createElement("div");
    this.world.dataset.pdContentWorld = "";
    this.world.style.cssText = "position:absolute;left:0;top:0;width:0;height:0;transform-origin:0 0;pointer-events:none";
    host.append(this.world);
    this.overlay = document.createElement("canvas");
    this.overlay.dataset.pdOverlay = "";
    this.overlay.style.cssText = "position:absolute;inset:0;width:100%;height:100%;display:block;pointer-events:none";
    host.append(this.overlay);
    this.ctx = this.overlay.getContext("2d")!;
    const ro = new ResizeObserver(() => this.resize());
    ro.observe(host);
    this.disposers.push(() => ro.disconnect());
    this.resize();
    this.listen();
  }

  dispose(): void {
    this.endEdit();
    for (const d of this.disposers) d();
    for (const f of this.frames) f.destroy();
    this.frames = [];
    this.world.remove();
    this.overlay.remove();
  }

  // ------------------------------------------------------------ the page

  /** Opens a page: its frames for the breakpoint view, fitted to the width. */
  async open(page: PageSource): Promise<void> {
    this.endEdit();
    this.page = page;
    this.content = page.content;
    this.history = new History();
    this.selection = [];
    this.hover = null;
    await this.build();
    const first = this.frames[0];
    if (first) {
      const info = readInfo(first.root);
      this.blocks = info.blocks;
      this.fields = info.fields;
    }
    this.placeView();
    this.publish();
  }

  /** The frames for the current view: one breakpoint, or all of them side by side. */
  async rebuild(): Promise<void> {
    if (!this.page) return;
    this.endEdit();
    if (this.frames[0]) this.content = serialize(this.frames[0].root);
    await this.build();
    this.placeView();
    this.publish();
  }

  /** Where the camera starts on a page or a view: fitted (Fit on), or across the width. */
  private placeView(): void {
    if (view.fit) this.fit();
    else this.fitWidth();
  }

  private async build(): Promise<void> {
    const page = this.page!;
    const run = ++this.building;
    for (const f of this.frames) f.destroy();
    const devices = view.all ? DEVICES : view.device ? [deviceOf(view.device)] : [freeDevice(view.freeWidth)];
    const frames = devices.map((d) => new Frame(this.world, d, page, this.content, () => this.layout()));
    this.frames = frames;
    this.layout();
    await Promise.all(frames.map((f) => f.ready));
    if (run !== this.building) return;
    for (const f of frames) this.listenFrame(f);
    this.layout();
  }

  /** The frames side by side, tops aligned. */
  private layout(): void {
    // A free width grows from its middle, as a responsive viewport does.
    // Side by side, breakpoints of one device sit closer than the devices do.
    let x = this.free() ? -this.frames[0].w / 2 : 0;
    this.frames.forEach((f, i) => {
      const prev = this.frames[i - 1];
      if (prev) x += prev.device.device === f.device.device ? GAP / 2 : GAP;
      f.place(x, 0);
      x += f.w;
    });
    this.request();
  }

  /** Free responsive mode: one frame of any width. */
  private free(): boolean {
    return !view.all && view.device === "" && this.frames.length === 1;
  }

  /** The frames' extent: left, right, the tallest's bottom. */
  private bounds(): [number, number, number] {
    if (!this.frames.length) return [0, 0, 0];
    const last = this.frames[this.frames.length - 1];
    return [this.frames[0].x, last.x + last.w, Math.max(...this.frames.map((f) => f.y + f.h))];
  }

  /** The content as annotated HTML (the data pipeline: what a host stores). */
  documentHtml(): string {
    const root = this.frames[0]?.root;
    if (!root) return "";
    return downcast(upcastBlocks(serialize(root)), "data");
  }

  // ------------------------------------------------------------ the camera

  /** The view is fitted to the width (until the person pans or zooms): a panel opening or
   * closing fits it again, as the block editor's page follows its pane. */
  private fitted = false;
  private lastWidth = 0;

  private resize(): void {
    this.dpr = window.devicePixelRatio || 1;
    const r = this.host.getBoundingClientRect();
    if (this.lastWidth && r.width !== this.lastWidth) {
      if (view.fit) {
        const y = this.cam.y * this.cam.z;
        this.fit();
        this.cam = { ...this.cam, y: y / this.cam.z };
        this.clampFit();
      } else if (this.fitted) {
        // Fitted again; the same part of the page stays at the top.
        const y = this.cam.y;
        this.fitWidth();
        this.cam = { ...this.cam, y };
      } else this.cam = { ...this.cam, x: this.cam.x - (r.width - this.lastWidth) / 2 / this.cam.z };
    }
    this.lastWidth = r.width;
    this.overlay.width = Math.max(1, Math.round(r.width * this.dpr));
    this.overlay.height = Math.max(1, Math.round(r.height * this.dpr));
    this.camDirty = true;
    this.request();
  }

  private size(): [number, number] {
    const r = this.host.getBoundingClientRect();
    return [r.width, r.height];
  }

  setCamera(cam: Camera): void {
    this.cam = { x: cam.x, y: cam.y, z: clamp(cam.z, MIN_ZOOM, MAX_ZOOM) };
    this.camDirty = true;
    view.zoomLabel = `${Math.round(this.cam.z * 100)}%`;
    this.request();
  }

  /** Zooms to `z` keeping the page point under CSS pixel (sx, sy) where it is. */
  zoomAt(sx: number, sy: number, z: number): void {
    z = clamp(z, MIN_ZOOM, MAX_ZOOM);
    const c = this.cam;
    const wx = c.x + sx / c.z;
    const wy = c.y + sy / c.z;
    this.setCamera({ z, x: wx - sx / z, y: wy - sy / z });
  }

  zoomBy(f: number): void {
    this.leaveFit();
    this.fitted = false;
    const [w, h] = this.size();
    this.zoomAt(w / 2, h / 2, this.cam.z * f);
  }

  zoomTo(z: number): void {
    this.leaveFit();
    this.fitted = false;
    const [w, h] = this.size();
    this.zoomAt(w / 2, h / 2, z);
  }

  /** Zoom to fit width: every frame across the canvas (never above 100%), from the top. */
  fitWidth(): void {
    const [w] = this.size();
    const [x0, x1] = this.bounds();
    const total = x1 - x0;
    if (!total) return;
    const z = clamp(Math.min(1, (w - PAD_X * 2) / total), MIN_ZOOM, MAX_ZOOM);
    this.setCamera({ z, x: x0 + total / 2 - w / 2 / z, y: -PAD_TOP / z });
    this.fitted = true;
  }

  /** Fit mode's view: as zoom to fit width, held there (the canvas only scrolls the page
   * up and down) until a zoom or a pan leaves it. */
  fit(): void {
    this.fitWidth();
  }

  /** The Fit toggle. */
  setFit(on: boolean): void {
    view.fit = on;
    saveViewPref();
    if (on) this.fit();
  }

  private leaveFit(): void {
    if (!view.fit) return;
    view.fit = false;
    saveViewPref();
  }

  /** Fit mode scrolls the page only within its length. */
  private clampFit(): void {
    const [, h] = this.size();
    const [, , bottom] = this.bounds();
    const z = this.cam.z;
    const top = -PAD_TOP / z;
    const end = Math.max(top, bottom + PAD_TOP / z - h / z);
    this.setCamera({ ...this.cam, y: clamp(this.cam.y, top, end) });
  }

  /** Zoom to 100%: exactly 100%, the frames' top left corner at the canvas's padding; a
   * frame narrower than the canvas stays in the middle. Pan and zoom stay free. */
  zoom100(): void {
    this.leaveFit();
    this.fitted = false;
    const [w] = this.size();
    const [x0, x1] = this.bounds();
    const total = x1 - x0;
    const x = total <= w - PAD_X * 2 ? x0 + total / 2 - w / 2 : x0 - PAD_X;
    this.setCamera({ z: 1, x, y: -PAD_TOP });
  }

  private applyCamera(): void {
    const c = this.cam;
    const d = this.dpr;
    const tx = Math.round(-c.x * c.z * d) / d;
    const ty = Math.round(-c.y * c.z * d) / d;
    this.world.style.transform = `translate(${tx}px, ${ty}px) scale(${c.z})`;
    // Moving: one layer the compositor moves. Settled: drawn again at the new scale.
    if (this.world.style.willChange !== "transform") this.world.style.willChange = "transform";
    window.clearTimeout(this.settle);
    this.settle = window.setTimeout(() => {
      this.world.style.willChange = "auto";
      this.lastFrame = 0;
    }, 180);
  }

  /** Page point to CSS pixel. */
  private toScreen(px: number, py: number): [number, number] {
    const c = this.cam;
    return [(px - c.x) * c.z, (py - c.y) * c.z];
  }

  private toPage(sx: number, sy: number): [number, number] {
    const c = this.cam;
    return [c.x + sx / c.z, c.y + sy / c.z];
  }

  private local(e: MouseEvent): [number, number] {
    const r = this.host.getBoundingClientRect();
    return [e.clientX - r.left, e.clientY - r.top];
  }

  // ------------------------------------------------------------ drawing

  request(): void {
    if (this.scheduled) return;
    this.scheduled = true;
    requestAnimationFrame((t) => {
      this.scheduled = false;
      if (this.camDirty) {
        this.camDirty = false;
        this.applyCamera();
        if (this.lastFrame) this.perf.push(t - this.lastFrame);
        this.lastFrame = t;
        if (this.perf.length > 2000) this.perf.splice(0, 1000);
      }
      this.draw();
    });
  }

  private painter(): Painter {
    return { ctx: this.ctx, dpr: this.dpr, screen: (x, y) => this.toScreen(x, y), zoom: () => this.cam.z };
  }

  private draw(): void {
    const ctx = this.ctx;
    const d = this.dpr;
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.clearRect(0, 0, this.overlay.width, this.overlay.height);
    ctx.setTransform(d, 0, 0, d, 0, 0);
    const p = this.painter();
    const css = getComputedStyle(document.documentElement);
    const nameColor = css.getPropertyValue("--pd-text-2").trim() || "rgba(0,0,0,0.5)";
    ctx.font = `500 11px "PD Inter", Inter, system-ui, sans-serif`;
    ctx.textBaseline = "alphabetic";
    this.frames.forEach((f, i) => {
      const [x, y] = this.toScreen(f.x, f.y);
      const on = this.edit?.frame === f || (this.selection.length > 0 && i === this.active && this.frames.length > 1);
      ctx.fillStyle = on ? BLUE : nameColor;
      // Cut to the frame's width, as Figma cuts frame names ("Mobile · Base < 7…").
      const [x1] = this.toScreen(f.x + f.w, f.y);
      const label = cut(ctx, this.frameLabel(f, i), x1 - x);
      if (label) ctx.fillText(label, Math.round(x), Math.round(y - 6));
    });
    if (!view.all && this.frames.length === 1) this.drawHandles(ctx, nameColor);
    this.drawDividers(ctx, nameColor);
    const sel = new Set(this.selection);
    // The hover, in the frame under the pointer only.
    if (this.hover && !sel.has(this.hover.key) && this.edit?.key !== this.hover.key) {
      const b = this.frames[this.hover.frame]?.box(this.hover.key);
      if (b) this.rect(p, b, 2);
    }
    for (const key of this.selection) {
      this.frames.forEach((f, i) => {
        const b = f.box(key);
        if (!b) return;
        this.rect(p, b, 1);
        if (this.selection.length === 1 && i === this.active && !this.edit) {
          const [x0, , x1, y1] = b;
          const [sx0, sy1] = this.toScreen(x0, y1);
          const [sx1] = this.toScreen(x1, y1);
          pill(p, `${Math.round(x1 - x0)} × ${Math.round(b[3] - b[1])}`, (sx0 + sx1) / 2, sy1 + 14, BLUE);
        }
      });
    }
    if (this.selection.length > 1) {
      const f = this.frames[this.active];
      let u: Box | null = null;
      for (const key of this.selection) {
        const b = f?.box(key);
        if (b) u = u ? [Math.min(u[0], b[0]), Math.min(u[1], b[1]), Math.max(u[2], b[2]), Math.max(u[3], b[3])] : b;
      }
      if (u) {
        const [sx0, sy1] = this.toScreen(u[0], u[3]);
        const [sx1] = this.toScreen(u[2], u[3]);
        pill(p, `${Math.round(u[2] - u[0])} × ${Math.round(u[3] - u[1])}`, (sx0 + sx1) / 2, sy1 + 14, BLUE);
      }
    }
    this.placeToolbar();
    const g = this.gesture;
    if (g?.kind === "marquee" && g.on) {
      const [ax, ay] = crisp(p, Math.min(g.x0, g.x1), Math.min(g.y0, g.y1));
      const [bx, by] = crisp(p, Math.max(g.x0, g.x1), Math.max(g.y0, g.y1));
      ctx.fillStyle = "rgba(13,153,255,0.08)";
      ctx.fillRect(ax, ay, bx - ax, by - ay);
      ctx.strokeStyle = BLUE;
      ctx.lineWidth = 1;
      ctx.strokeRect(ax, ay, bx - ax, by - ay);
    }
  }

  /** A box's outline, `width` CSS px drawn inside its edge. */
  private rect(p: Painter, b: Box, width: number): void {
    const ctx = p.ctx;
    const [x0, y0] = p.screen(b[0], b[1]);
    const [x1, y1] = p.screen(b[2], b[3]);
    const d = p.dpr;
    const r = (v: number) => Math.round(v * d) / d;
    const inset = width / 2;
    ctx.strokeStyle = BLUE;
    ctx.lineWidth = width;
    ctx.strokeRect(r(x0) + inset, r(y0) + inset, Math.max(0, r(x1) - r(x0) - width), Math.max(0, r(y1) - r(y0) - width));
  }

  // ------------------------------------------------------------ what is where

  private frameAt(px: number, py: number): number {
    return this.frames.findIndex((f) => f.contains(px, py));
  }

  /** The block the selection is inside (its fields are selected or edited), or "". */
  scope(): string {
    if (this.edit) return this.edit.info.block;
    if (!this.selection.length || this.selection.some(isBlock)) return "";
    const b = blockOf(this.selection[0]);
    return this.selection.every((k) => blockOf(k) === b) ? b : "";
  }

  /** What a press at page point (px, py) reaches: a block, or a field of the block the
   * selection is in; nothing but the content's bound, editable elements. */
  private targetAt(px: number, py: number): Hit | null {
    const i = this.frameAt(px, py);
    if (i < 0) return null;
    const el = this.frames[i].elementAt(px, py);
    const block = el?.closest("[data-pd-block]");
    if (!el || !block) return null;
    const key = block.getAttribute("data-pd-block")!;
    if (this.scope() === key) return { key: this.fieldAt(el) ?? key, frame: i };
    return { key, frame: i };
  }

  private fieldAt(el: Element): string | null {
    const field = el.closest("[data-pd-field]");
    if (!field) return null;
    const key = field.getAttribute("data-pd-field")!;
    // A field that takes no room (an empty caption) is not offered.
    return this.frames[0]?.box(key) || this.frames.some((f) => f.box(key)) ? key : null;
  }

  // ------------------------------------------------------------ selection

  select(keys: string[], frame = this.active): void {
    this.selection = [...new Set(keys)];
    this.active = clamp(frame, 0, Math.max(0, this.frames.length - 1));
    this.publish();
    this.request();
  }

  /** Esc: out of a text edit, then from a field to its block, then nothing. */
  up(): void {
    if (this.edit) {
      this.endEdit();
      return;
    }
    const scope = this.scope();
    this.select(scope ? [scope] : []);
  }

  /** Enter: into a block (its first field), into a text (editing it all), an image's file. */
  down(): void {
    if (this.selection.length !== 1) return;
    const key = this.selection[0];
    if (isBlock(key)) {
      const first = this.blocks.get(key)?.fields.find((k) => this.frames.some((f) => f.box(k)));
      if (first) this.select([first]);
      return;
    }
    const info = this.fields.get(key);
    if (info?.text) this.startEdit(this.frames[this.active] ?? this.frames[0], key, "all");
    else if (info?.image) this.onPickImage?.(key);
  }

  selectAll(): void {
    const scope = this.scope();
    if (scope) this.select(this.blocks.get(scope)?.fields.filter((k) => this.frames.some((f) => f.box(k))) ?? []);
    else this.select([...this.blocks.keys()]);
  }

  // ------------------------------------------------------------ the pointer and keys

  private listen(): void {
    const host = this.host;
    const on = <K extends keyof HTMLElementEventMap>(target: HTMLElement | Window, type: K, fn: (e: HTMLElementEventMap[K]) => void, opts?: AddEventListenerOptions | boolean) => {
      target.addEventListener(type, fn as EventListener, opts);
      this.disposers.push(() => target.removeEventListener(type, fn as EventListener, opts));
    };
    on(host, "wheel", (e) => this.wheel(e), { passive: false });
    on(host, "mousedown", (e) => {
      this.down_(e);
      if (!this.gesture || this.gesture.kind === "press") this.hoverAt(e);
    });
    on(host, "mousemove", (e) => {
      if (!this.gesture) this.hoverAt(e);
    });
    on(host, "mouseleave", () => {
      if (this.hover) {
        this.hover = null;
        this.request();
      }
    });
    on(host, "auxclick", (e) => {
      if (e.button === 1) e.preventDefault();
    });
    on(host, "contextmenu", (e) => e.preventDefault());
    // A focus inside a frame may scroll the canvas to reveal it; the canvas never scrolls.
    on(host, "scroll", () => {
      host.scrollTop = 0;
      host.scrollLeft = 0;
    });
    on(window, "mousemove", (e) => this.move(e));
    on(window, "mouseup", (e) => this.up_(e));
    on(window, "keydown", (e) => this.key(e, null));
    on(window, "keyup", (e) => {
      if (e.code === "Space") {
        this.spaceDown = false;
        this.cursor();
      }
    });
    on(window, "blur", () => {
      this.spaceDown = false;
      this.cursor();
    });
  }

  private wheel(e: WheelEvent): void {
    e.preventDefault();
    this.fitted = false;
    let dx = e.deltaX;
    let dy = e.deltaY;
    if (e.deltaMode === 1) {
      dx *= 16;
      dy *= 16;
    } else if (e.deltaMode === 2) {
      const [w, h] = this.size();
      dx *= w;
      dy *= h;
    }
    if (e.ctrlKey || e.metaKey) {
      // A pinch arrives as ctrl+wheel with small deltas; a wheel's notches are big.
      this.leaveFit();
      const [sx, sy] = this.local(e);
      this.zoomAt(sx, sy, this.cam.z * Math.exp(-clamp(dy, -60, 60) * 0.01));
      return;
    }
    if (e.shiftKey && dx === 0) {
      dx = dy;
      dy = 0;
    }
    if (view.fit) {
      // Fit holds the width: the wheel scrolls the page, as a fitted viewport does.
      this.setCamera({ ...this.cam, y: this.cam.y + dy / this.cam.z });
      this.clampFit();
      return;
    }
    this.setCamera({ ...this.cam, x: this.cam.x + dx / this.cam.z, y: this.cam.y + dy / this.cam.z });
  }

  private cursor(over: "text" | "resize" | "" = ""): void {
    this.host.style.cursor =
      this.gesture?.kind === "pan" ? "grabbing" : this.gesture?.kind === "resize" || over === "resize" ? "ew-resize" : this.spaceDown || view.tool === "hand" ? "grab" : over === "text" ? "text" : "default";
  }

  private handleHover: 0 | 1 | -1 = 0;

  /** The width handles on the frame's sides, at CSS pixel (sx, sy): on any single frame,
   * hidden until the pointer is over one; never with all breakpoints side by side. */
  private handleAt(sx: number, sy: number): 0 | 1 | -1 {
    if (view.all || this.frames.length !== 1 || this.spaceDown || view.tool === "hand") return 0;
    const f = this.frames[0];
    const [x0, y0] = this.toScreen(f.x, f.y);
    const [x1, y1] = this.toScreen(f.x + f.w, f.y + f.h);
    if (sy < y0 || sy > y1) return 0;
    if (sx >= x1 && sx <= x1 + 16) return 1;
    if (sx <= x0 && sx >= x0 - 16) return -1;
    return 0;
  }

  private hoverAt(e: MouseEvent): void {
    const [sx, sy] = this.local(e);
    const [px, py] = this.toPage(sx, sy);
    const side = this.handleAt(sx, sy);
    if (side !== this.handleHover) {
      this.handleHover = side;
      this.request();
    }
    if (side) {
      this.cursor("resize");
      if (this.hover) {
        this.hover = null;
        this.request();
      }
      return;
    }
    const hit = this.spaceDown || view.tool === "hand" ? null : this.targetAt(px, py);
    const overText = this.edit && this.overEdit(px, py);
    this.cursor(overText || (hit && this.fields.get(hit.key)?.text && this.edit?.key === hit.key) ? "text" : "");
    if (hit?.key !== this.hover?.key || hit?.frame !== this.hover?.frame) {
      this.hover = hit;
      this.request();
    }
  }

  /** Page point (px, py) is in the text being edited, in its frame. */
  private overEdit(px: number, py: number): boolean {
    const ed = this.edit;
    if (!ed || !ed.frame.contains(px, py)) return false;
    const r = ed.el.getBoundingClientRect();
    const x = px - ed.frame.x;
    const y = py - ed.frame.y;
    return x >= r.left && x <= r.right && y >= r.top && y <= r.bottom;
  }

  private down_(e: MouseEvent): void {
    const [sx, sy] = this.local(e);
    if (e.button === 1 || (e.button === 0 && (this.spaceDown || view.tool === "hand"))) {
      e.preventDefault();
      this.leaveFit();
      this.gesture = { kind: "pan", x: e.clientX, y: e.clientY };
      this.cursor();
      return;
    }
    if (e.button !== 0) return;
    // The text being edited keeps the focus; the press places its caret or selects.
    e.preventDefault();
    const side = this.handleAt(sx, sy);
    if (side) {
      if (this.edit) this.endEdit();
      this.startResize();
      this.gesture = { kind: "resize", side, x: e.clientX, w: this.frames[0].w };
      return;
    }
    (document.activeElement as HTMLElement | null)?.blur?.();
    const [px, py] = this.toPage(sx, sy);
    const count = e.detail || 1;
    if (this.edit && this.overEdit(px, py)) {
      this.textPress(px, py, count, e.shiftKey);
      return;
    }
    if (this.edit) this.endEdit();
    const i = this.frameAt(px, py);
    if (i >= 0) this.active = i;
    const hit = this.targetAt(px, py);
    if (count >= 2 && !e.shiftKey && hit) {
      this.dive(hit, px, py, count);
      return;
    }
    if (!hit) {
      const scope = this.scope();
      const base = e.shiftKey ? this.selection : [];
      if (!e.shiftKey) this.select([], i);
      this.gesture = { kind: "marquee", x0: px, y0: py, x1: px, y1: py, base, scope, on: false };
      return;
    }
    if (e.shiftKey) {
      const has = this.selection.includes(hit.key);
      this.select(has ? this.selection.filter((k) => k !== hit.key) : [...this.selection, hit.key], hit.frame);
      return;
    }
    const info = this.fields.get(hit.key);
    const again = this.selection.length === 1 && this.selection[0] === hit.key;
    this.select([hit.key], hit.frame);
    if (again && info?.image && !info.text) this.onPickImage?.(hit.key);
    this.gesture = { kind: "press", x: px, y: py };
  }

  /** Double-click: into the block under the pointer, to the field there; a text starts
   * editing with all of it selected, an image asks for a file. */
  private dive(hit: Hit, px: number, py: number, count: number): void {
    const frame = this.frames[hit.frame];
    let key = hit.key;
    if (isBlock(key)) {
      const el = frame.elementAt(px, py);
      const field = el ? this.fieldAt(el) : null;
      if (!field || blockOf(field) !== key) return;
      key = field;
    }
    this.select([key], hit.frame);
    const info = this.fields.get(key);
    if (info?.text) this.startEdit(frame, key, "all");
    else if (info?.image && count === 2) this.onPickImage?.(key);
  }

  private move(e: MouseEvent): void {
    const g = this.gesture;
    if (!g) return;
    if (g.kind === "resize") {
      const w = clamp(Math.round(g.w + ((e.clientX - g.x) / this.cam.z) * 2 * g.side), FREE_MIN, FREE_MAX);
      if (w !== this.frames[0].w) {
        this.frames[0].setWidth(w);
        view.freeWidth = w;
        this.layout();
        this.publishBreakpoint();
      }
      return;
    }
    if (g.kind === "pan") {
      this.fitted = false;
      this.setCamera({ ...this.cam, x: this.cam.x - (e.clientX - g.x) / this.cam.z, y: this.cam.y - (e.clientY - g.y) / this.cam.z });
      g.x = e.clientX;
      g.y = e.clientY;
      return;
    }
    const [sx, sy] = this.local(e);
    const [px, py] = this.toPage(sx, sy);
    if (g.kind === "text") {
      this.textDrag(px, py, g);
      return;
    }
    if (g.kind === "marquee") {
      g.x1 = px;
      g.y1 = py;
      if (!g.on && Math.hypot((g.x1 - g.x0) * this.cam.z, (g.y1 - g.y0) * this.cam.z) > 3) g.on = true;
      if (g.on) this.marquee(g);
      this.request();
    }
  }

  private up_(e: MouseEvent): void {
    const g = this.gesture;
    if (!g) return;
    this.gesture = null;
    if (g.kind === "marquee") this.request();
    if (g.kind === "resize") saveViewPref();
    this.cursor();
    this.hoverAt(e);
  }

  /** The marquee selects what it touches: blocks, or the fields of the block the
   * selection was in when it started there. */
  private marquee(g: Extract<Gesture, { kind: "marquee" }>): void {
    const box: Box = [Math.min(g.x0, g.x1), Math.min(g.y0, g.y1), Math.max(g.x0, g.x1), Math.max(g.y0, g.y1)];
    const scopeBox = g.scope ? this.frames.map((f) => f.box(g.scope)).find((b) => b && b[0] <= g.x0 && b[2] >= g.x0 && b[1] <= g.y0 && b[3] >= g.y0) : null;
    const candidates = scopeBox ? (this.blocks.get(g.scope)?.fields ?? []) : [...this.blocks.keys()];
    const hits = candidates.filter((key) => this.frames.some((f) => {
      const b = f.box(key);
      return b !== null && b[0] < box[2] && b[2] > box[0] && b[1] < box[3] && b[3] > box[1];
    }));
    const next = [...g.base, ...hits];
    if (next.join() !== this.selection.join()) this.select(next);
  }

  /** Keys: from the window, or from a frame while its text is edited (`frame`). */
  key(e: KeyboardEvent, frame: Frame | null): void {
    if (!this.page) return;
    const target = e.target as HTMLElement | null;
    if (!frame && target && (target.closest?.("input, textarea, select, [role=menu], [role=listbox]") || target.isContentEditable)) return;
    const mod = e.metaKey || e.ctrlKey;
    const k = e.key.toLowerCase();
    if (mod && (e.code === "Equal" || e.code === "NumpadAdd")) {
      e.preventDefault();
      this.zoomBy(2);
      return;
    }
    if (mod && (e.code === "Minus" || e.code === "NumpadSubtract")) {
      e.preventDefault();
      this.zoomBy(0.5);
      return;
    }
    if (mod && e.code === "Digit0") {
      e.preventDefault();
      this.zoom100();
      return;
    }
    if (mod && k === "z") {
      e.preventDefault();
      if (e.shiftKey) this.redo();
      else this.undo();
      return;
    }
    if (mod && k === "y") {
      e.preventDefault();
      this.redo();
      return;
    }
    if (mod && e.code === "Backslash") {
      e.preventDefault();
      view.uiHidden = !view.uiHidden;
      return;
    }
    if (this.edit) {
      if (e.key === "Escape") {
        e.preventDefault();
        this.endEdit();
      } else if (e.key === "Tab") e.preventDefault();
      else if (mod && ["b", "i", "u"].includes(k)) {
        const f = k === "b" ? "bold" : k === "i" ? "italic" : "underline";
        if (!this.edit.info.formats.includes(f)) e.preventDefault();
      }
      return;
    }
    if (e.code === "Space") {
      e.preventDefault();
      if (!this.spaceDown) {
        this.spaceDown = true;
        this.cursor();
      }
      return;
    }
    if (e.shiftKey && e.code === "Digit1") {
      e.preventDefault();
      this.fitWidth();
    } else if (e.shiftKey && e.code === "Digit0") {
      e.preventDefault();
      this.zoom100();
    } else if (!mod && (e.code === "Equal" || e.code === "NumpadAdd")) {
      e.preventDefault();
      this.zoomBy(2);
    } else if (!mod && (e.code === "Minus" || e.code === "NumpadSubtract")) {
      e.preventDefault();
      this.zoomBy(0.5);
    } else if (e.key === "Escape") {
      e.preventDefault();
      this.up();
    } else if (e.key === "Enter") {
      e.preventDefault();
      if (e.shiftKey) this.up();
      else this.down();
    } else if (mod && k === "a") {
      e.preventDefault();
      this.selectAll();
    } else if (!mod && !e.shiftKey && !e.altKey && k === "v") view.tool = "move";
    else if (!mod && !e.shiftKey && !e.altKey && k === "h") view.tool = "hand";
    else return;
    this.cursor();
  }

  // ------------------------------------------------------------ text

  /** Starts editing text field `key` in `frame`: all of it selected, or the caret at an
   * offset. */
  startEdit(frame: Frame, key: string, at: "all" | number): void {
    const info = this.fields.get(key);
    const el = frame.el(key);
    if (!info?.text || !el) return;
    if (this.edit) this.endEdit();
    el.setAttribute("contenteditable", "true");
    el.spellcheck = false;
    // A block that is its own carrier keeps its settings island in the text's element.
    const islands = [...el.children].filter((c) => c.localName === "script").map((c) => c.cloneNode(true) as Element);
    this.edit = { frame, key, el, info, session: ++this.sessions, islands };
    this.active = this.frames.indexOf(frame);
    this.selection = [key];
    frame.iframe.contentWindow?.focus();
    el.focus({ preventScroll: true });
    const len = textOf(el).length;
    if (at === "all") selectOffsets(el, 0, len);
    else selectOffsets(el, at, at);
    this.host.scrollTop = 0;
    this.host.scrollLeft = 0;
    this.publish();
    this.request();
  }

  /** Ends the text edit: the field stays selected; its typing becomes one undo step. */
  endEdit(): void {
    const ed = this.edit;
    if (!ed) return;
    this.edit = null;
    ed.el.removeAttribute("contenteditable");
    ed.el.blur();
    ed.frame.doc.getSelection()?.removeAllRanges();
    // The keys come back to the editor's page.
    if (document.activeElement === ed.frame.iframe) ed.frame.iframe.blur();
    this.history.close(ed.session, { selection: [ed.key], editing: "", caret: null });
    this.selection = [ed.key];
    this.publish();
    this.request();
  }

  private textPress(px: number, py: number, count: number, shift: boolean): void {
    const ed = this.edit!;
    ed.el.focus({ preventScroll: true });
    const o = offsetAtPoint(ed.el, px - ed.frame.x, py - ed.frame.y);
    const text = textOf(ed.el);
    if (count === 1) {
      const cur = selectionOffsets(ed.el);
      const anchor = shift && cur ? cur[0] : o;
      selectOffsets(ed.el, anchor, o);
      this.gesture = { kind: "text", anchor: [anchor, anchor], grain: "char" };
      return;
    }
    const [a, b] = count === 2 ? wordAt(text, o) : lineAt(text, o);
    selectOffsets(ed.el, a, b);
    this.gesture = { kind: "text", anchor: [a, b], grain: count === 2 ? "word" : "line" };
  }

  private textDrag(px: number, py: number, g: Extract<Gesture, { kind: "text" }>): void {
    const ed = this.edit;
    if (!ed) return;
    const o = offsetAtPoint(ed.el, px - ed.frame.x, py - ed.frame.y);
    if (g.grain === "char") {
      selectOffsets(ed.el, g.anchor[0], o);
      return;
    }
    const text = textOf(ed.el);
    const [a, b] = g.grain === "word" ? wordAt(text, o) : lineAt(text, o);
    if (o < g.anchor[0]) selectOffsets(ed.el, g.anchor[1], a);
    else selectOffsets(ed.el, g.anchor[0], Math.max(b, g.anchor[1]));
  }

  private snap(caret: [number, number] | null = null): Snap {
    return { selection: [...this.selection], editing: this.edit?.key ?? "", caret };
  }

  /** The frame's keys and typing go through here while its text is edited. */
  private listenFrame(frame: Frame): void {
    const doc = frame.doc;
    // Keys pressed while a frame has the focus are the canvas's too (never the browser's
    // own undo in the frame).
    doc.addEventListener("keydown", (e) => this.key(e, this.edit?.frame === frame ? frame : null), true);
    doc.addEventListener("keyup", (e) => {
      if (e.code === "Space") this.spaceDown = false;
    });
    doc.addEventListener("beforeinput", (e) => this.beforeInput(frame, e));
    doc.addEventListener("input", (e) => this.input(frame, e as InputEvent));
    doc.addEventListener("dragstart", (e) => e.preventDefault());
  }

  private beforeInput(frame: Frame, e: InputEvent): void {
    const ed = this.edit;
    if (!ed || ed.frame !== frame) return;
    if (this.muted) return;
    const t = e.inputType;
    if (t === "historyUndo" || t === "historyRedo") {
      e.preventDefault();
      if (t === "historyUndo") this.undo();
      else this.redo();
      return;
    }
    if (t.startsWith("format")) {
      const f = FORMAT_INPUT[t];
      if (!f || !ed.info.formats.includes(f)) {
        e.preventDefault();
        return;
      }
    }
    if (t === "insertParagraph" || t === "insertLineBreak") {
      e.preventDefault();
      // A text of one line: Enter ends the edit. With line breaks: one more.
      if (!ed.info.breaks) {
        if (t === "insertParagraph") this.endEdit();
        return;
      }
      this.programmatic(() => this.insertBreak(ed), "insert");
      return;
    }
    if (t === "insertFromPaste" || t === "insertFromDrop" || t === "insertFromYank" || t === "insertReplacementText") {
      e.preventDefault();
      let text = e.dataTransfer?.getData("text/plain") ?? e.data ?? "";
      if (!ed.info.breaks) text = text.replace(/\s*[\r\n]+\s*/g, " ");
      this.programmatic(() => {
        text.split(/\r?\n/).forEach((line, i) => {
          if (i) this.insertBreak(ed);
          if (line) frame.doc.execCommand("insertText", false, line);
        });
      }, "");
      return;
    }
    this.pending = { html: ed.el.innerHTML, caret: selectionOffsets(ed.el) };
  }

  private insertBreak(ed: Edit): void {
    if (ed.info.newlines) ed.frame.doc.execCommand("insertText", false, "\n");
    else ed.frame.doc.execCommand("insertLineBreak");
  }

  /** An edit made by the canvas itself (a pasted text, a line break): one step. */
  private programmatic(run: () => void, kind: string): void {
    const ed = this.edit!;
    const before = { html: ed.el.innerHTML, caret: selectionOffsets(ed.el) };
    this.muted = true;
    try {
      run();
    } finally {
      this.muted = false;
    }
    this.record(ed, before, kind);
  }

  private input(frame: Frame, e: InputEvent): void {
    const ed = this.edit;
    if (!ed || ed.frame !== frame || this.muted) return;
    const before = this.pending ?? { html: ed.el.innerHTML, caret: null };
    this.pending = null;
    if (e.inputType.startsWith("format")) this.normalizeMarks(ed);
    const kind = e.inputType.startsWith("insert") ? "insert" : e.inputType.startsWith("delete") ? "delete" : "";
    this.record(ed, before, kind);
  }

  /** The browser bolds with `<b>` and slants with `<i>`; the content's own tags stay. */
  private normalizeMarks(ed: Edit): void {
    const caret = selectionOffsets(ed.el);
    const doc = ed.frame.doc;
    for (const [from, to] of [
      ["b", "strong"],
      ["i", "em"],
    ]) {
      if (ed.el.querySelector(to) === null && ed.info.formats.length && !ed.el.querySelector(from)) continue;
      for (const old of [...ed.el.querySelectorAll(from)]) {
        const next = doc.createElement(to);
        next.append(...old.childNodes);
        old.replaceWith(next);
      }
    }
    if (caret) selectOffsets(ed.el, caret[0], caret[1]);
  }

  private record(ed: Edit, before: { html: string; caret: [number, number] | null }, kind: string): void {
    // Typing over everything may take the settings island with it: it comes back.
    if (ed.islands.length && !ed.el.querySelector(":scope > script")) {
      const caret = selectionOffsets(ed.el);
      ed.el.prepend(...ed.islands.map((i) => i.cloneNode(true)));
      if (caret) selectOffsets(ed.el, caret[0], caret[1]);
    }
    const html = ed.el.innerHTML;
    if (html === before.html) return;
    for (const f of this.frames) {
      if (f === ed.frame) continue;
      const other = f.el(ed.key);
      if (other) other.innerHTML = html;
    }
    const step: Step = {
      key: ed.key,
      before: { html: before.html },
      after: { html },
      selBefore: this.snap(before.caret),
      selAfter: this.snap(selectionOffsets(ed.el)),
      session: ed.session,
      kind,
      time: performance.now(),
    };
    this.history.push(step);
    this.publish();
    this.request();
  }

  // ------------------------------------------------------------ attributes (images, links)

  /** Sets attributes of field `key` in every frame, as one undo step. */
  setAttrs(key: string, attrs: Record<string, string | null>): void {
    const el = this.frames[0]?.el(key);
    if (!el) return;
    const before: Record<string, string | null> = {};
    for (const name of Object.keys(attrs)) before[name] = el.getAttribute(name);
    if (Object.keys(attrs).every((n) => before[n] === attrs[n])) return;
    if (this.edit) this.endEdit();
    this.write(key, { attrs });
    const snap = this.snap();
    this.history.push({ key, before: { attrs: before }, after: { attrs }, selBefore: snap, selAfter: snap, session: 0, kind: "", time: performance.now() });
    this.publish();
    this.request();
  }

  /** The block toolbar's B, I, U, S on the text being edited (the formats it allows). */
  format(f: Format): void {
    const ed = this.edit;
    if (!ed || !ed.info.formats.includes(f)) return;
    const cmd: Partial<Record<Format, string>> = { bold: "bold", italic: "italic", underline: "underline", strikethrough: "strikeThrough", subscript: "subscript", superscript: "superscript" };
    const name = cmd[f];
    if (!name) return;
    ed.el.focus({ preventScroll: true });
    ed.frame.doc.execCommand(name);
  }

  /** An image chosen for field `key`: shown from memory until saving comes. */
  setImage(key: string, file: File): void {
    const url = URL.createObjectURL(file);
    const alt = this.frames[0]?.el(key)?.getAttribute("alt") ?? "";
    this.setAttrs(key, { src: url, srcset: null, alt: alt || file.name.replace(/\.[^.]+$/, "") });
  }

  private write(key: string, value: Value): void {
    for (const f of this.frames) {
      const el = f.el(key);
      if (!el) continue;
      if ("html" in value) el.innerHTML = value.html;
      else
        for (const [name, v] of Object.entries(value.attrs)) {
          if (v === null) el.removeAttribute(name);
          else el.setAttribute(name, v);
        }
    }
  }

  // ------------------------------------------------------------ undo

  undo(): void {
    if (this.edit) {
      const top = this.history.undo[this.history.undo.length - 1];
      if (!top || top.session !== this.edit.session) this.endEdit();
    }
    const step = this.history.undo.pop();
    if (!step) return;
    this.history.redo.push(step);
    this.apply(step, step.before, step.selBefore);
  }

  redo(): void {
    if (this.edit) {
      const top = this.history.redo[this.history.redo.length - 1];
      if (!top || top.session !== this.edit.session) this.endEdit();
    }
    const step = this.history.redo.pop();
    if (!step) return;
    this.history.undo.push(step);
    this.apply(step, step.after, step.selAfter);
  }

  private apply(step: Step, value: Value, snap: Snap): void {
    this.write(step.key, value);
    const ed = this.edit;
    if (ed && ed.key === step.key && step.session === ed.session) {
      if (snap.caret) selectOffsets(ed.el, snap.caret[0], snap.caret[1]);
    } else {
      if (ed) this.endEdit();
      this.selection = snap.selection.filter((k) => this.blocks.has(k) || this.fields.has(k));
    }
    this.publish();
    this.request();
  }

  // ------------------------------------------------------------ what the chrome shows

  /** List View rows folded open by hand (blocks open by themselves while selected). */
  expanded = new Set<string>();

  /** Where a style edit would land, mobile first: the breakpoint picked, the one a free
   * width falls in, or with all side by side the frame the selection is in. */
  private editingBreakpoint(): DeviceKey {
    if (view.all) {
      const key = this.frames[this.active]?.device.key;
      return key && key !== "free" ? key : "mobile";
    }
    if (view.device) return view.device;
    return breakpointAt(view.freeWidth).key as DeviceKey;
  }

  private publishBreakpoint(): void {
    const bp = this.editingBreakpoint();
    if (view.editingBreakpoint !== bp) view.editingBreakpoint = bp;
    this.request();
  }

  /** "Tablet · ≥ 768px · editing Tablet", "Responsive · 834px · editing Tablet". */
  private frameLabel(f: Frame, i: number): string {
    const editing = deviceOf(this.editingBreakpoint()).label;
    const on = !view.all || i === this.active;
    if (f.device.key === "free") return `Responsive · ${f.w}px · editing ${editing}`;
    return on ? `${frameName(f.device)} · editing ${editing}` : frameName(f.device);
  }

  /** Side by side: a dashed rule between devices, as the block editor's design system
   * separates its device groups. */
  private drawDividers(ctx: CanvasRenderingContext2D, color: string): void {
    const [, h] = this.size();
    for (let i = 1; i < this.frames.length; i++) {
      const a = this.frames[i - 1];
      const b = this.frames[i];
      if (a.device.device === b.device.device) continue;
      const [x] = this.toScreen((a.x + a.w + b.x) / 2, 0);
      const [, y0] = this.toScreen(0, a.y - 24);
      ctx.save();
      ctx.strokeStyle = color;
      ctx.globalAlpha = 0.5;
      ctx.setLineDash([4, 4]);
      ctx.lineWidth = 1;
      ctx.beginPath();
      ctx.moveTo(Math.round(x) + 0.5, Math.max(0, y0));
      ctx.lineTo(Math.round(x) + 0.5, h);
      ctx.stroke();
      ctx.restore();
    }
  }

  /** Dragging a width: a fixed breakpoint becomes free responsive mode at its width, the
   * frame staying where it is on screen; Fit turns off (it never refits while dragging). */
  private startResize(): void {
    this.leaveFit();
    this.fitted = false;
    const f = this.frames[0];
    if (view.device === "") return;
    const x = f.x;
    view.freeWidth = f.w;
    view.device = "";
    f.device = freeDevice(f.w);
    this.layout();
    this.cam = { ...this.cam, x: this.cam.x + (f.x - x) };
    this.camDirty = true;
    this.publish();
    saveViewPref();
  }

  /** The side handles, at the middle of the part in view: only the one under the pointer
   * or being dragged. */
  private drawHandles(ctx: CanvasRenderingContext2D, color: string): void {
    const f = this.frames[0];
    const [, h] = this.size();
    const [x0, y0] = this.toScreen(f.x, f.y);
    const [x1, y1] = this.toScreen(f.x + f.w, f.y + f.h);
    const top = Math.max(y0, 0);
    const bottom = Math.min(y1, h);
    if (bottom - top < 24) return;
    const mid = Math.round((top + bottom) / 2);
    for (const side of [-1, 1] as const) {
      const on = this.handleHover === side || (this.gesture?.kind === "resize" && this.gesture.side === side);
      if (!on) continue;
      const x = side === 1 ? Math.round(x1) + 5 : Math.round(x0) - 11;
      ctx.fillStyle = on ? BLUE : color;
      ctx.beginPath();
      ctx.roundRect(x, mid - 24, 6, 48, 3);
      ctx.fill();
    }
  }

  publish(): void {
    view.editingBreakpoint = this.editingBreakpoint();
    const before = view.selection.join();
    view.selection = [...this.selection];
    view.editing = this.edit?.key ?? "";
    view.canUndo = this.history.undo.length > 0;
    view.canRedo = this.history.redo.length > 0;
    view.edits = this.history.undo.length;
    view.inspector = this.inspector();
    view.layers = this.layerRows();
    view.breadcrumb = this.crumbs();
    view.outline = this.outline();
    // As in the block editor, picking a block shows the Block tab; none, the Document tab.
    if (before !== view.selection.join()) view.sidebar = this.selection.length ? "block" : "document";
    if (view.output) this.writeOutput();
    this.placeToolbar();
  }

  writeOutput(): void {
    const root = this.frames[0]?.root;
    if (!root) return;
    const editing = serialize(root);
    view.outputEditing = downcast(upcastBlocks(editing), "editing");
    view.outputData = downcast(upcastBlocks(editing), "data");
  }

  /** The block type of the element owning a field (`heading`, `button`). */
  private typeOf(key: string): string {
    const el = this.frames[0]?.el(key);
    return el?.closest("[data-pb-block]")?.getAttribute("data-pb-block") ?? "";
  }

  private iconOf(key: string): string {
    if (isBlock(key)) {
      const el = this.frames[0]?.el(key);
      return el?.hasAttribute("data-pb-pattern") ? "pattern" : (blockType(el?.getAttribute("data-pb-block") ?? "")?.icon ?? "components");
    }
    const info = this.fields.get(key);
    if (info?.image && !info.text) return "image";
    return blockType(this.typeOf(key))?.icon ?? "paragraph";
  }

  private preview(key: string): string {
    const el = this.frames[0]?.el(key);
    if (!el) return "";
    const info = this.fields.get(key);
    if (info?.image && !info.text) return el.getAttribute("alt") || "";
    return textOf(el).replace(/\s+/g, " ").trim().slice(0, 80);
  }

  private visible(key: string): boolean {
    return this.frames.some((f) => f.box(key));
  }

  private inspector(): typeof view.inspector {
    const sel = this.selection;
    if (!sel.length) return { kind: "page" };
    if (sel.length > 1) return { kind: "many", count: sel.length, title: sel.every(isBlock) ? `${sel.length} blocks` : `${sel.length} fields` };
    const key = sel[0];
    if (isBlock(key)) {
      const b = this.blocks.get(key);
      const el = this.frames[0]?.el(key);
      const pattern = el?.getAttribute("data-pb-pattern") ?? "";
      const description = (pattern && getPattern(pattern)?.description) || blockType(el?.getAttribute("data-pb-block") ?? "")?.description || "";
      const rows: FieldRow[] = (b?.fields ?? [])
        .filter((k) => this.visible(k))
        .map((k) => {
          const info = this.fields.get(k)!;
          return { key: k, label: info.label, icon: this.iconOf(k), kind: info.text ?? (info.image ? "image" : "link"), preview: this.preview(k), selected: false };
        });
      return { kind: "block", key, title: b?.label ?? "Block", icon: this.iconOf(key), pattern: pattern !== "", description, rows };
    }
    const info = this.fields.get(key)!;
    const el = this.frames[0]?.el(key);
    return {
      kind: "field",
      key,
      title: info.label,
      icon: this.iconOf(key),
      description: blockType(this.typeOf(key))?.description ?? "",
      block: info.block,
      blockTitle: this.blocks.get(info.block)?.label ?? "",
      text: info.text,
      formats: info.formats,
      image: info.image,
      src: info.image ? (el?.getAttribute("src") ?? "") : "",
      alt: info.image ? (el?.getAttribute("alt") ?? "") : "",
      link: info.link,
      href: info.link ? (el?.getAttribute("href") ?? "") : "",
    };
  }

  /** The List View: the template's parts around the Content slot, the page's blocks in
   * it, a block's fields under it while it is open. */
  private layerRows(): LayerRow[] {
    const rows: LayerRow[] = [];
    const scope = this.scope() || (this.selection.length === 1 && isBlock(this.selection[0]) ? this.selection[0] : "");
    const sel = new Set(this.selection);
    const doc = this.frames[0]?.doc;
    const parts = doc ? [...doc.querySelectorAll("[data-publr-template-part]")].map((el) => el.getAttribute("data-publr-template-part") ?? "") : [];
    const part = (name: string) => rows.push({ key: `part:${name}`, label: titled(name), detail: "", icon: "components", depth: 0, selected: false, open: false, hasChildren: false, kind: "part" });
    const root = this.frames[0]?.root;
    const isBefore = (name: string) => {
      const el = doc?.querySelector(`[data-publr-template-part="${name}"]`);
      return !!(el && root && el.compareDocumentPosition(root) & Node.DOCUMENT_POSITION_FOLLOWING);
    };
    for (const name of parts) if (isBefore(name)) part(name);
    const slotOpen = !view.collapsed.includes("slot");
    rows.push({ key: "slot", label: "Content", detail: "", icon: "stack", depth: 0, selected: false, open: slotOpen, hasChildren: this.blocks.size > 0, kind: "slot" });
    if (slotOpen)
      for (const b of this.blocks.values()) {
        const open = b.key === scope || this.expanded.has(b.key);
        const self = b.fields.length === 1 && this.frames[0]?.el(b.fields[0]) === this.frames[0]?.el(b.key);
        rows.push({ key: b.key, label: b.label, detail: self ? this.preview(b.fields[0]) : "", icon: this.iconOf(b.key), depth: 1, selected: sel.has(b.key) || (self && sel.has(b.fields[0])), open: open && !self, hasChildren: b.fields.length > 0 && !self, kind: "block" });
        if (self) continue;
        if (!open) continue;
        for (const k of b.fields) {
          if (!this.visible(k)) continue;
          const info = this.fields.get(k)!;
          rows.push({ key: k, label: info.label, detail: this.preview(k), icon: this.iconOf(k), depth: 2, selected: sel.has(k), open: false, hasChildren: false, kind: "field" });
        }
      }
    for (const name of parts) if (!isBefore(name)) part(name);
    return rows;
  }

  /** A List View row's chevron. */
  toggleRow(key: string): void {
    if (key === "slot") {
      view.collapsed = view.collapsed.includes("slot") ? view.collapsed.filter((k) => k !== "slot") : [...view.collapsed, "slot"];
    } else if (this.expanded.has(key)) this.expanded.delete(key);
    else this.expanded.add(key);
    view.layers = this.layerRows();
  }

  private crumbs(): { key: string; label: string }[] {
    if (this.selection.length !== 1) return [];
    const key = this.selection[0];
    const block = blockOf(key);
    const out = [{ key: block, label: this.blocks.get(block)?.label ?? "" }];
    const same = this.frames[0]?.el(key) === this.frames[0]?.el(block);
    if (!isBlock(key) && !same) out.push({ key, label: this.fields.get(key)?.label ?? "" });
    return out;
  }

  /** The Outline tab: characters, words, the time to read, the headings. */
  private outline(): typeof view.outline {
    const root = this.frames[0]?.root;
    if (!root) return { characters: 0, words: 0, minutes: 1, headings: [] };
    const text = textOf(root);
    const words = text.split(/\s+/).filter(Boolean).length;
    const headings = [...root.querySelectorAll("h1, h2, h3, h4, h5, h6")].map((h) => {
      const level = Number(h.localName.slice(1));
      return { key: h.getAttribute("data-pd-field") ?? "", level: h.localName.toUpperCase(), text: textOf(h).replace(/\s+/g, " ").trim(), guide: (level - 1) * 12 };
    });
    return { characters: text.replace(/\s/g, "").length, words, minutes: Math.max(1, Math.round(words / 200)), headings };
  }

  /** The block toolbar sits over the selection's top left, in the frame it was picked in. */
  private placeToolbar(): void {
    const t = view.toolbar;
    const key = this.selection.length === 1 ? this.selection[0] : "";
    const b = key && this.gesture?.kind !== "pan" && this.gesture?.kind !== "marquee" ? this.frames[this.active]?.box(key) : null;
    if (!b) {
      if (t.shown) view.toolbar = { shown: false, x: 0, y: 0 };
      return;
    }
    const [sx, sy] = this.toScreen(b[0], b[1]);
    const [, ey] = this.toScreen(b[2], b[3]);
    const [w, h] = this.size();
    // Out of view: no toolbar (it never sticks to an edge over something else).
    if (ey < 0 || sy > h) {
      if (t.shown) view.toolbar = { shown: false, x: 0, y: 0 };
      return;
    }
    const x = Math.round(clamp(sx, 8, Math.max(8, w - 320)));
    const y = Math.round(clamp(sy - 48, 8, Math.max(8, h - 48)));
    if (!t.shown || t.x !== x || t.y !== y) view.toolbar = { shown: true, x, y };
  }

  /** The panels' hover on a row shows it on the canvas. */
  hoverKey(key: string): void {
    this.hover = key && (this.blocks.has(key) || this.fields.has(key)) ? { key, frame: this.active } : null;
    this.request();
  }
}

const titled = (s: string) => s.replace(/-/g, " ").replace(/^\w/, (c) => c.toUpperCase());

/** `text` as it fits in `room` CSS pixels in the context's font, cut with an ellipsis. */
function cut(ctx: CanvasRenderingContext2D, text: string, room: number): string {
  if (ctx.measureText(text).width <= room) return text;
  let lo = 0;
  let hi = text.length;
  while (lo < hi) {
    const mid = (lo + hi + 1) >> 1;
    if (ctx.measureText(text.slice(0, mid).trimEnd() + "\u2026").width <= room) lo = mid;
    else hi = mid - 1;
  }
  return lo ? text.slice(0, lo).trimEnd() + "\u2026" : "";
}
