// The canvas: a document page on an infinite plane, drawn by PublrEngine in WASM.
//
// The engine renders on the CPU, 10-500 ms a frame, so the canvas never waits for it:
// the page is cut into 256-device-pixel tiles per power-of-two zoom level, rendered in
// Web Workers (each holds its own engine session) and composited here with drawImage.
// While a tile is on its way the nearest coarser or finer level stands in, scaled, so
// panning and zooming stay at display rate and sharpen as tiles arrive. The queue is
// rebuilt from the view on every frame (visible first, nearest the centre first), so
// tiles that scrolled away are never started; finished tiles live in an LRU cache.
//
// With WebGPU the page is drawn whole every frame instead (gpu.ts): the engine on this
// thread walks the scene into primitives and the GPU draws them, the workers drawing on
// the CPU only what the GPU cannot draw yet. The view then moves by whole device pixels,
// so a node's numbers (and its cached CPU layers) stay put while it pans. The 2D canvas
// stays on top for the frame names and the selection.

import { feedOf } from "./feed";
import { keep } from "./keep";
import type { DocInfo, Engine, Hit, Page } from "./engine";
import type { GpuCanvas, GpuStats } from "./gpu";
import { RecordsCanvas } from "./records";
import type { Pool, Slot } from "./pool";

export const TILE = 256;
const MIN_LEVEL = -12;
const MAX_LEVEL = 10;
export const MIN_ZOOM = 0.01;
export const MAX_ZOOM = 256;
/** How far past a power of two the coarser level still serves (a tenth of a level). */
const LEVEL_BIAS = 0.1;

/** A rendered tile; `stale` once an edit painted inside it (drawn until its new one comes). */
type Tile = { key: string; bitmap: ImageBitmap | null; bytes: number; used: number; stale?: boolean };
type Job = { key: string; gen: number; page: number; level: number; tx: number; ty: number; pri: number; dist: number };

/** One tile render, for the timings. */
export type Timing = { ms: number; level: number; zoom: number; drawn: number; culled: number; empty: boolean };

/** What the chrome shows about the canvas. */
export type View = {
  zoom: number;
  level: number;
  pending: number;
  tiles: number;
  cacheBytes: number;
  lastMs: number;
  fps: number;
  drawMs: number;
  /** Each worker's engine memory, bytes. */
  wasmBytes: number[];
  /** The GPU frame's numbers, when the GPU draws. */
  gpu: GpuStats | null;
};

export type Camera = { x: number; y: number; z: number };

/** A document's view kept while another shows: the page, its camera, every page's
 * camera, the selection (`keepView`, `showKept`). */
export type KeptView = { page: number; cam: Camera; cameras: Map<number, Camera>; selected: (Hit & { page: number }) | null };

/** Decoded images handed to the engine per frame, ms (at least one a frame). */
const INSTALL_MS = 4;
/** A page switch waits at most this long for the new page to be whole, ms. */
const SWITCH_MAX_MS = 8000;
/** The veil over the old page while the new one is prepared: a soft blur (CSS px) and
 * a wash of the page's background over it. */
const VEIL_BLUR = 6;
const VEIL_WASH = 0.45;
/** How long writing a page's records may run per frame, ms (a top-level node at least). */
const RECORDS_SLICE_MS = 8;
/** The view counts as resting this long after it last moved, ms. */
const REST_MS = 400;

const clamp = (v: number, a: number, b: number) => Math.min(b, Math.max(a, v));

const cssColor = (c: number[]) => `rgb(${Math.round(c[0] * 255)},${Math.round(c[1] * 255)},${Math.round(c[2] * 255)})`;

export class Stage {
  readonly canvas: HTMLCanvasElement;
  private ctx: CanvasRenderingContext2D;
  pool: Pool | null = null;
  doc: DocInfo | null = null;
  page = 0;
  /** Bumped when a document opens: answers for older ones are dropped. */
  private gen = 0;
  /** The page point at the canvas's top left; z: CSS pixels per page unit. */
  cam: Camera = { x: 0, y: 0, z: 1 };
  private cameras = new Map<number, Camera>();
  private dpr = 1;
  tiles = new Map<string, Tile>();
  bytes = 0;
  private inflight = new Map<string, Job>();
  /** Tiles on their way that an edit painted inside after they were asked for. */
  private staleInflight = new Set<string>();
  private queue: Job[] = [];
  private frameNo = 0;
  timings: Timing[] = [];
  private lastMs = 0;
  private frameTimes: number[] = [];
  private lastFrameAt = 0;
  private drawMs = 0;
  private drawRequested = false;
  private spaceDown = false;
  private drag: { x: number; y: number; id: number; click: boolean } | null = null;
  private selected: (Hit & { page: number }) | null = null;
  private cacheBytes: number;
  private reportAt = 0;
  private reportTimer = 0;
  /** Called (at most a few times a second) with what the chrome shows. */
  onView: (view: View) => void = () => {};
  /** Called with the node a click lands on, or null. */
  onSelect: (hit: Hit | null) => void = () => {};
  /** Called after every frame of an open document with what it still waits for (0:
   * the view is whole and sharp); the viewer's splash goes on it. */
  onDrawn: ((pending: number) => void) | null = null;
  /** The GPU canvas and the engine on this thread that feeds it (null: CPU tiles). */
  gpu: GpuCanvas | null = null;
  private recordsOn = false;
  /** Records on the GPU per document and page: each page kept read keeps its own, so
   * showing it again is a camera and a draw. They go with their page (`dropRecords`) or
   * their document (`dropEngine`). */
  private recordsOf = new Map<Engine, Map<number, RecordsCanvas>>();
  /** Documents whose records could not be written: drawn by frames built each time. */
  private recordsFailed = new WeakSet<Engine>();
  private engineNow: Engine | null = null;
  /** The records canvas drawn last (a canvas shown again is brought up to date first:
   * edits elsewhere may have changed its page). */
  private recordsLast: RecordsCanvas | null = null;

  /** The engine on this thread that holds the shown document (one per open document):
   * the GPU canvas's caches and the records follow it. */
  get engine(): Engine | null {
    return this.engineNow;
  }

  set engine(e: Engine | null) {
    this.engineNow = e;
    if (e && this.gpu) this.gpu.useEngine(e);
  }

  /** The records of the page shown (made when new), or null when the page is drawn by
   * frames built each time (`?gpu=immediate`, or records that could not be written). */
  get records(): RecordsCanvas | null {
    const e = this.engineNow;
    if (!this.recordsOn || !this.gpu || !e || this.recordsFailed.has(e)) return null;
    let pages = this.recordsOf.get(e);
    if (!pages) this.recordsOf.set(e, (pages = new Map()));
    let rec = pages.get(this.page);
    if (!rec) pages.set(this.page, (rec = new RecordsCanvas(this.gpu, e, this.page)));
    return rec;
  }

  /** Whether page `index` of the shown document is kept whole: its nodes read and its
   * records on the GPU (showing it is a camera and a draw). */
  isKept(index: number): boolean {
    const e = this.engineNow;
    if (!e || !this.usingGpu() || !this.recordsOn || this.recordsFailed.has(e)) return false;
    const rec = this.recordsOf.get(e)?.get(index);
    if (!rec || !rec.has(index)) return false;
    const feed = feedOf(e);
    return !feed || feed.isLoaded(index);
  }

  /** Page `page` of `engine` is no longer kept: its records leave the GPU. */
  dropRecords(engine: Engine, page: number): void {
    const pages = this.recordsOf.get(engine);
    const rec = pages?.get(page);
    if (!rec) return;
    pages!.delete(page);
    if (this.recordsLast === rec) this.recordsLast = null;
    rec.destroy();
  }

  /** `engine`'s document is no longer kept (its file closed or parked): all its records go. */
  dropEngine(engine: Engine): void {
    const pages = this.recordsOf.get(engine);
    if (!pages) return;
    this.recordsOf.delete(engine);
    for (const rec of pages.values()) {
      if (this.recordsLast === rec) this.recordsLast = null;
      rec.destroy();
    }
  }

  /** Bytes the records of every kept page hold on the GPU, by document and page. */
  recordsBytes(): { engine: Engine; page: number; bytes: number }[] {
    const out: { engine: Engine; page: number; bytes: number }[] = [];
    for (const [engine, pages] of this.recordsOf) for (const [page, rec] of pages) out.push({ engine, page, bytes: rec.gpuBytes() });
    return out;
  }
  /** Draw with the GPU when there is one. */
  gpuOn = true;
  /** Set by an editor shell that draws its own marks over the canvas (frame names,
   * selection): called after every frame instead of the viewer's marks, and a click no
   * longer picks. */
  chrome: (() => void) | null = null;
  /** The Hand tool: a left drag pans, as Space-drag does. */
  handTool = false;
  /** Whether the view keys (Space, Shift+1, Shift+0, + and -, Escape) are this canvas's
   * now: with two canvases side by side, only the one in focus takes them. */
  keys: () => boolean = () => true;
  /** A page switch in progress on the GPU: the old page's last frame stays on screen
   * under a veil until the new page draws whole (null: none). */
  private switching: { since: number; built?: boolean } | null = null;
  /** Called when a page switch has put the new page up (ms it took). */
  onSwitched: ((ms: number) => void) | null = null;
  /** When the GPU frame last had CPU layers pending, and when they all arrived. */
  gpuPendingSince = 0;
  gpuSharpAt = 0;

  constructor(host: HTMLElement, cacheBytes: number) {
    this.cacheBytes = cacheBytes;
    this.canvas = document.createElement("canvas");
    this.canvas.style.cssText = "position:absolute;inset:0;width:100%;height:100%;display:block;touch-action:none";
    host.append(this.canvas);
    const ctx = this.canvas.getContext("2d");
    if (!ctx) throw new Error("no 2d canvas");
    this.ctx = ctx;
    this.listen();
    keep.gpu(() => this.recordsBytes().reduce((a, r) => a + r.bytes, 0));
    new ResizeObserver(() => this.resize()).observe(this.canvas);
    this.resize();
  }

  // ------------------------------------------------------------ document and camera

  /** Shows a newly opened document from page `page` (its first by default), fitted. */
  open(doc: DocInfo, page = 0): void {
    // The canvas may have been hidden until now: take its size before fitting.
    this.resize();
    this.endSwitch();
    this.gen++;
    this.clearTiles();
    this.cameras.clear();
    this.doc = doc;
    this.opening = true;
    this.page = Math.min(page, Math.max(0, doc.pages.length - 1));
    // An empty page fits nothing: it starts at 100% from the origin.
    this.cam = { x: 0, y: 0, z: 1 };
    this.select(null);
    this.fit();
  }

  /** The view as it is now, kept while another document shows (a workspace's tabs). */
  keepView(): KeptView {
    const cameras = new Map(this.cameras);
    cameras.set(this.page, { ...this.cam });
    return { page: this.page, cam: { ...this.cam }, cameras, selected: this.selected ? { ...this.selected } : null };
  }

  /** Shows `doc`, open already, as `view` kept it: its page, camera and selection, the
   * other pages' cameras (no fit, no veil). */
  showKept(doc: DocInfo, view: KeptView): void {
    this.resize();
    this.endSwitch();
    this.gen++;
    this.clearTiles();
    this.doc = doc;
    this.cameras = new Map(view.cameras);
    this.page = Math.min(view.page, Math.max(0, doc.pages.length - 1));
    this.cam = { ...(this.cameras.get(this.page) ?? view.cam) };
    const sel = view.selected && view.selected.page === this.page ? view.selected : null;
    this.selected = sel ? { ...sel } : null;
    this.onSelect(sel);
    this.requestDraw();
  }

  /** Shows nothing: the document is closed (answers still on their way are dropped). */
  close(): void {
    this.endSwitch();
    this.gen++;
    this.clearTiles();
    this.cameras.clear();
    this.doc = null;
    this.page = 0;
    this.select(null);
    this.timings = [];
  }

  /** An edit painted these page rects ([page, x0, y0, x1, y1]): the CPU tiles over them
   * draw again (the old ones show until the new ones come). The GPU needs nothing: what it
   * keeps is keyed by the nodes' revisions. */
  damage(rects: number[][]): void {
    if (!rects.length) return;
    this.gpu?.damage(rects);
    if (this.records) this.records.dirty = true;
    const hit = (key: string) => {
      const [gen, page, level, tx, ty] = key.split("/").map(Number);
      if (gen !== this.gen) return false;
      const ws = TILE / 2 ** level;
      // A tile draws a little beyond its edge (antialiasing, effects reach).
      const m = 4 / 2 ** level;
      const x0 = tx * ws - m;
      const y0 = ty * ws - m;
      const x1 = (tx + 1) * ws + m;
      const y1 = (ty + 1) * ws + m;
      return rects.some((r) => r[0] === page && r[3] > x0 && r[1] < x1 && r[4] > y0 && r[2] < y1);
    };
    for (const t of this.tiles.values()) if (hit(t.key)) t.stale = true;
    for (const key of this.inflight.keys()) if (hit(key)) this.staleInflight.add(key);
    this.requestDraw();
  }

  /** Forgets every tile and render (the next frame renders afresh). */
  clearTiles(): void {
    for (const t of this.tiles.values()) t.bitmap?.close();
    this.tiles.clear();
    this.bytes = 0;
    this.queue = [];
  }

  currentPage(): Page | null {
    return this.doc?.pages[this.page] ?? null;
  }

  showPage(index: number): void {
    if (index === this.page) return;
    // A page kept whole shows in the next frame, as it was left; another is prepared
    // behind the veil.
    if (this.isKept(index)) this.endSwitch();
    else this.startSwitch();
    this.cameras.set(this.page, { ...this.cam });
    this.page = index;
    this.select(null);
    const saved = this.cameras.get(index);
    if (saved) {
      this.cam = { ...saved };
      this.requestDraw();
    } else {
      this.fit();
    }
  }

  /** Whether a page switch is waiting for the new page (the old one shows veiled). */
  isSwitching(): boolean {
    return this.switching !== null;
  }

  /** Before the page changes on the GPU: the GPU canvas keeps showing the page shown
   * now (its frames are no longer put up), blurred, under a wash of the page's
   * background on the 2D canvas, while the new page is prepared behind it, as Figma's
   * canvas does. Only the canvas is veiled: the rulers and panels draw over it. */
  private startSwitch(): void {
    if (this.switching) {
      this.switching.since = performance.now();
      return;
    }
    if (!this.usingGpu() || !this.currentPage() || !this.doc) return;
    const ctx = this.ctx;
    const bg = this.background();
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.clearRect(0, 0, this.canvas.width, this.canvas.height);
    ctx.fillStyle = `rgba(${Math.round(bg[0] * 255)},${Math.round(bg[1] * 255)},${Math.round(bg[2] * 255)},${VEIL_WASH})`;
    ctx.fillRect(0, 0, this.canvas.width, this.canvas.height);
    this.gpu!.canvas.style.filter = `blur(${VEIL_BLUR}px)`;
    this.canvas.dataset.switching = "";
    this.switching = { since: performance.now() };
  }

  /** The new page is up (or the document changed): the veil goes. */
  private endSwitch(): void {
    const sw = this.switching;
    if (!sw) return;
    this.switching = null;
    window.clearTimeout(this.switchTimer);
    if (this.gpu) this.gpu.canvas.style.filter = "";
    delete this.canvas.dataset.switching;
    this.ctx.setTransform(1, 0, 0, 1, 0, 0);
    this.ctx.clearRect(0, 0, this.canvas.width, this.canvas.height);
    this.onSwitched?.(performance.now() - sw.since);
  }

  private cssSize(): [number, number] {
    return [this.canvas.width / this.dpr, this.canvas.height / this.dpr];
  }

  private resize(): void {
    this.dpr = window.devicePixelRatio || 1;
    const r = this.canvas.getBoundingClientRect();
    this.canvas.width = Math.max(1, Math.round(r.width * this.dpr));
    this.canvas.height = Math.max(1, Math.round(r.height * this.dpr));
    if (this.gpu) {
      this.gpu.canvas.width = this.canvas.width;
      this.gpu.canvas.height = this.canvas.height;
    }
    this.requestDraw();
  }

  /** Draws with `gpu` (fed by `engine`, which holds the same document as the workers). */
  attachGpu(gpu: GpuCanvas, engine: Engine): void {
    this.gpu = gpu;
    gpu.onChange = () => this.requestDraw();
    // Records unless the address asks for the frames built each time (`?gpu=immediate`).
    this.recordsOn = !(typeof location !== "undefined" && new URLSearchParams(location.search).get("gpu") === "immediate");
    gpu.onClear = () => {
      for (const pages of this.recordsOf.values()) for (const r of pages.values()) r.clear();
    };
    this.engine = engine;
    this.resize();
  }

  /** Whether the GPU draws now. */
  usingGpu(): boolean {
    return !!(this.gpu && this.engine && this.gpuOn);
  }

  /** Switches between the GPU and the CPU tiles. */
  setGpu(on: boolean): void {
    this.gpuOn = on;
    if (this.gpu) this.gpu.canvas.style.visibility = on ? "visible" : "hidden";
    this.requestDraw();
  }

  setCamera(cam: Camera): void {
    this.cam = { ...cam };
    this.requestDraw();
  }

  /** Zooms to `z`, keeping the page point under CSS pixel (px, py) in place. */
  zoomAt(px: number, py: number, z: number): void {
    z = clamp(z, MIN_ZOOM, MAX_ZOOM);
    const c = this.cam;
    const wx = c.x + px / c.z;
    const wy = c.y + py / c.z;
    this.cam = { z, x: wx - px / z, y: wy - py / z };
    this.requestDraw();
  }

  /** Zooms around the canvas's centre. */
  zoomTo(z: number): void {
    const [w, h] = this.cssSize();
    this.zoomAt(w / 2, h / 2, z);
  }

  /** Shows a page rect whole, centred. */
  showRect(x0: number, y0: number, x1: number, y1: number, pad = 48): void {
    const [w, h] = this.cssSize();
    const bw = Math.max(1, x1 - x0);
    const bh = Math.max(1, y1 - y0);
    const z = clamp(Math.min((w - pad * 2) / bw, (h - pad * 2) / bh), MIN_ZOOM, MAX_ZOOM);
    this.cam = { z, x: (x0 + x1) / 2 - w / 2 / z, y: (y0 + y1) / 2 - h / 2 / z };
    this.requestDraw();
  }

  /** Zoom to fit: every top-level node of the page. */
  fit(): void {
    const pg = this.currentPage();
    if (!pg || !pg.frames.length) {
      this.requestDraw();
      return;
    }
    let b = [Infinity, Infinity, -Infinity, -Infinity];
    for (const f of pg.frames) b = [Math.min(b[0], f.box[0]), Math.min(b[1], f.box[1]), Math.max(b[2], f.box[2]), Math.max(b[3], f.box[3])];
    this.showRect(b[0], b[1], b[2], b[3]);
  }

  private devScale(): number {
    return this.cam.z * this.dpr;
  }

  private levelFor(dev: number): number {
    return clamp(Math.ceil(Math.log2(dev) - LEVEL_BIAS), MIN_LEVEL, MAX_LEVEL);
  }

  private keyOf(page: number, level: number, tx: number, ty: number): string {
    return `${this.gen}/${page}/${level}/${tx}/${ty}`;
  }

  private background(): number[] {
    return this.currentPage()?.background ?? [0.96, 0.96, 0.96];
  }

  /** Whether anything on the page may paint inside the tile. */
  private tileHasContent(level: number, tx: number, ty: number): boolean {
    const pg = this.currentPage();
    if (!pg) return false;
    const ws = TILE / 2 ** level;
    const margin = 4 / 2 ** level;
    const x0 = tx * ws - margin;
    const y0 = ty * ws - margin;
    const x1 = (tx + 1) * ws + margin;
    const y1 = (ty + 1) * ws + margin;
    for (const f of pg.frames) {
      const b = f.bounds;
      if (b[2] > x0 && b[0] < x1 && b[3] > y0 && b[1] < y1) return true;
    }
    return false;
  }

  // ------------------------------------------------------------ drawing

  requestDraw(): void {
    if (this.drawRequested) return;
    this.drawRequested = true;
    requestAnimationFrame((now) => this.frame(now));
  }

  /** Device-pixel rect of a page rect, edges rounded so neighbouring tiles meet exactly. */
  private screenRect(wx0: number, wy0: number, wx1: number, wy1: number): [number, number, number, number] {
    const dev = this.devScale();
    const x0 = Math.round((wx0 - this.cam.x) * dev);
    const y0 = Math.round((wy0 - this.cam.y) * dev);
    const x1 = Math.round((wx1 - this.cam.x) * dev);
    const y1 = Math.round((wy1 - this.cam.y) * dev);
    return [x0, y0, x1 - x0, y1 - y0];
  }

  /** Draws what stands in for a missing tile: a coarser ancestor's part, then finer
   * children over it. Returns whether something covers it. */
  private drawStandIn(level: number, tx: number, ty: number): boolean {
    const ws = TILE / 2 ** level;
    const [dx, dy, dw, dh] = this.screenRect(tx * ws, ty * ws, (tx + 1) * ws, (ty + 1) * ws);
    let covered = false;
    for (let k = 1; k <= 10 && level - k >= MIN_LEVEL; k++) {
      const f = 2 ** k;
      const ax = Math.floor(tx / f);
      const ay = Math.floor(ty / f);
      const t = this.tiles.get(this.keyOf(this.page, level - k, ax, ay));
      if (!t) continue;
      t.used = this.frameNo;
      if (t.bitmap) {
        const sw = TILE / f;
        this.ctx.drawImage(t.bitmap, (tx - ax * f) * sw, (ty - ay * f) * sw, sw, sw, dx, dy, dw, dh);
      }
      covered = true;
      break;
    }
    if (level + 1 <= MAX_LEVEL) {
      const cws = ws / 2;
      for (let j = 0; j < 2; j++) {
        for (let i = 0; i < 2; i++) {
          const cx = tx * 2 + i;
          const cy = ty * 2 + j;
          const t = this.tiles.get(this.keyOf(this.page, level + 1, cx, cy));
          if (!t) continue;
          t.used = this.frameNo;
          if (!t.bitmap) continue;
          const [x, y, w, h] = this.screenRect(cx * cws, cy * cws, (cx + 1) * cws, (cy + 1) * cws);
          this.ctx.drawImage(t.bitmap, x, y, w, h);
        }
      }
    }
    return covered;
  }

  /** Draws one frame from what is cached and queues what is missing. */
  frame(now: number): void {
    this.drawRequested = false;
    const t0 = performance.now();
    if (this.lastFrameAt) {
      this.frameTimes.push(now - this.lastFrameAt);
      if (this.frameTimes.length > 120) this.frameTimes.shift();
    }
    this.lastFrameAt = now;
    this.frameNo++;

    const ctx = this.ctx;
    const cw = this.canvas.width;
    const ch = this.canvas.height;
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    const pg = this.currentPage();
    if (this.usingGpu() && pg) {
      // While a switch waits, the 2D canvas holds the veiled old page.
      if (!this.switching) ctx.clearRect(0, 0, cw, ch);
      this.gpuFrame(pg);
      this.drawMs = performance.now() - t0;
      this.report();
      this.onDrawn?.(this.pending());
      return;
    }
    ctx.fillStyle = cssColor(this.background());
    ctx.fillRect(0, 0, cw, ch);
    if (!pg) {
      this.report();
      if (this.doc) this.onDrawn?.(0);
      return;
    }

    const dev = this.devScale();
    const level = this.levelFor(dev);
    const ws = TILE / 2 ** level;
    const { x: cx, y: cy } = this.cam;
    const vx1 = cx + cw / dev;
    const vy1 = cy + ch / dev;
    const tx0 = Math.floor(cx / ws);
    const ty0 = Math.floor(cy / ws);
    const tx1 = Math.floor(vx1 / ws);
    const ty1 = Math.floor(vy1 / ws);
    const midX = (cx + vx1) / 2;
    const midY = (cy + vy1) / 2;
    ctx.imageSmoothingEnabled = true;
    ctx.imageSmoothingQuality = "medium";

    const wanted: Job[] = [];
    const want = (lv: number, tx: number, ty: number, pri: number) => {
      const key = this.keyOf(this.page, lv, tx, ty);
      if (this.inflight.has(key)) return;
      const have = this.tiles.get(key);
      if (have && !have.stale) return;
      const w = TILE / 2 ** lv;
      const dist = Math.hypot((tx + 0.5) * w - midX, (ty + 0.5) * w - midY);
      wanted.push({ key, gen: this.gen, page: this.page, level: lv, tx, ty, pri, dist });
    };

    for (let ty = ty0; ty <= ty1; ty++) {
      for (let tx = tx0; tx <= tx1; tx++) {
        if (!this.tileHasContent(level, tx, ty)) continue;
        const t = this.tiles.get(this.keyOf(this.page, level, tx, ty));
        if (t) {
          t.used = this.frameNo;
          if (t.bitmap) {
            const [x, y, w, h] = this.screenRect(tx * ws, ty * ws, (tx + 1) * ws, (ty + 1) * ws);
            ctx.drawImage(t.bitmap, x, y, w, h);
          }
          if (t.stale) want(level, tx, ty, 0);
          continue;
        }
        const covered = this.drawStandIn(level, tx, ty);
        // Nothing stands in: a coarse tile first (one covers sixteen), then the real one.
        if (!covered && level - 2 >= MIN_LEVEL) {
          const ax = Math.floor(tx / 4);
          const ay = Math.floor(ty / 4);
          if (this.tileHasContent(level - 2, ax, ay)) want(level - 2, ax, ay, 0);
        }
        want(level, tx, ty, 1);
      }
    }
    // A ring around the view, for panning.
    for (let ty = ty0 - 1; ty <= ty1 + 1; ty++) {
      for (let tx = tx0 - 1; tx <= tx1 + 1; tx++) {
        if (ty >= ty0 && ty <= ty1 && tx >= tx0 && tx <= tx1) continue;
        if (this.tileHasContent(level, tx, ty)) want(level, tx, ty, 2);
      }
    }
    wanted.sort((a, b) => a.pri - b.pri || a.dist - b.dist);
    this.queue = wanted;
    this.pump();

    this.drawOverlay(pg);
    this.drawMs = performance.now() - t0;
    this.report();
    this.onDrawn?.(this.pending());
  }

  /** The camera of the last GPU frame, and until when the view counts as moving. */
  private lastCam: Camera = { x: 0, y: 0, z: 0 };
  /** Whether the last GPU frame had everything it draws. */
  private gpuComplete = true;
  private movingUntil = 0;
  private switchTimer = 0;
  private settleTimer = 0;

  /** The page drawn by the GPU at the camera moved to whole device pixels. While the
   * zoom changes, the engine draws with stand-ins of nearby scales (glyph masks,
   * polylines); a frame once it settles draws them exact. */
  private gpuFrame(pg: Page): void {
    const gpu = this.gpu!;
    const dev = this.devScale();
    const now = performance.now();
    if (this.cam.z !== this.lastCam.z) this.movingUntil = now + 150;
    this.lastCam = { ...this.cam };
    const moving = now < this.movingUntil;
    this.engine!.gpuMotion(moving);
    if (moving) {
      clearTimeout(this.settleTimer);
      this.settleTimer = window.setTimeout(() => this.requestDraw(), this.movingUntil - now + 5);
    }
    const x = Math.round(this.cam.x * dev) / dev;
    const y = Math.round(this.cam.y * dev) / dev;
    // A document read in pieces: what this frame lacks is read, and drawn when in.
    const feed = feedOf(this.engine!);
    let complete = true;
    if (feed) {
      feed.onReady = () => this.requestDraw();
      const engine = this.engine!;
      feed.show(this.page);
      feed.onUnload = (p) => this.dropRecords(engine, p);
      feed.gpuBytes = (p) => this.recordsOf.get(engine)?.get(p)?.gpuBytes() ?? 0;
      complete = feed.ready(this.page, x, y, dev, gpu.canvas.width, gpu.canvas.height);
      // Images decoded in the workers come in a few a frame (each is a copy into the
      // engine and a texture upload).
      if (feed.install(INSTALL_MS)) this.requestDraw();
    }
    const switching = this.switching;
    // A switch waits for the new page's nodes before drawing anything of it, and builds
    // its frame again only once the images the last one asked for are in (a frame of a
    // big page is tens of ms of this thread). The first build goes while the page's
    // images decode (the feed asked for them as the nodes came in).
    if (switching && (!complete || (switching.built && feed?.busy() && !this.records)) && performance.now() - switching.since < SWITCH_MAX_MS) {
      this.gpuComplete = false;
      this.drawOverlay(pg);
      return;
    }
    if (switching) switching.built = true;
    const whole = () => complete && (!feed || feed.rendered());
    if (this.records) {
      this.recordsFrame(pg, x, y, dev, complete, whole, switching);
      return;
    }
    // A view costly to build each frame is kept on the GPU: moved, scaled while the zoom
    // changes, and built again only where it lacks (gpu.ts `drawKept`).
    if (!switching && complete && gpu.costly) {
      let sharp = false;
      try {
        sharp = gpu.drawKept(this.engine!, this.page, x, y, dev, this.background(), whole, moving);
      } catch (err) {
        console.error("gpu frame", err);
      }
      this.gpuComplete = sharp && !moving;
      if (gpu.keptBuilding()) this.requestDraw();
      this.drawOverlay(pg);
      return;
    }
    try {
      gpu.drawPage(this.engine!, this.page, x, y, dev, this.background(), whole, !switching);
    } catch (err) {
      console.error("gpu frame", err);
    }
    this.gpuComplete = gpu.lastComplete && !moving;
    if (switching) {
      // The new page goes up in one frame once it draws whole: its images in, no CPU
      // layers or glyph masks to come.
      const ready = gpu.lastComplete && gpu.stats.pending === 0 && !gpu.stats.glyphsDeferred;
      if (ready || performance.now() - switching.since > SWITCH_MAX_MS) {
        gpu.presentLast();
        this.endSwitch();
      } else if (gpu.stats.glyphsDeferred) {
        this.requestDraw();
      } else {
        // Woken by what it waits for (images, layers); the cap is a timer.
        window.clearTimeout(this.switchTimer);
        this.switchTimer = window.setTimeout(() => this.requestDraw(), SWITCH_MAX_MS - (performance.now() - switching.since) + 5);
      }
    }
    const pending = gpu.stats.pending;
    if (pending && !this.gpuPendingSince) {
      this.gpuPendingSince = performance.now();
      this.gpuSharpAt = 0;
    } else if (!pending && this.gpuPendingSince) {
      this.gpuSharpAt = performance.now();
      this.gpuPendingSince = 0;
    }
    this.drawOverlay(pg);
  }

  /** A frame from the records kept on the GPU: written once per page (and again after an
   * edit), then each frame only places the top-level nodes. */
  private recordsCam = [0, 0, 0];
  /** A document opened and not yet drawn whole (the viewer's splash covers it). */
  private opening = false;
  /** The engine's bytes when the page's records began to be written. */
  private recordsLive = 0;
  private recordsMoved = 0;
  private restTimer = 0;

  private recordsFrame(pg: Page, x: number, y: number, dev: number, complete: boolean, whole: () => boolean, switching: { since: number; built?: boolean } | null): void {
    const rec = this.records!;
    const engine = this.engine!;
    const moving = performance.now() < this.movingUntil;
    try {
      if (complete && !rec.has(this.page)) {
        try {
          // Written a top-level node at a time, about 8 ms a frame: the frames go on (the
          // old page veiled) and decoded images come in between.
          if (!rec.writing) this.recordsLive = engine.live();
          if (!rec.buildSome(engine, RECORDS_SLICE_MS)) {
            // The rest in tasks of their own, not one a frame: input and the workers'
            // answers come in between.
            this.gpuComplete = false;
            const page = this.page;
            const more = () => {
              if (!rec.writing || this.records !== rec) return;
              if (!rec.buildSome(engine, RECORDS_SLICE_MS)) {
                window.setTimeout(more, 0);
                return;
              }
              this.recordsWritten(engine, page);
              this.requestDraw();
            };
            window.setTimeout(more, 0);
            this.drawOverlay(pg);
            return;
          }
          this.recordsWritten(engine, this.page);
        } catch (err) {
          // A page the records cannot hold (memory): this file's frames are built each
          // time instead.
          console.error("records: falling back to frames built each time", err);
          this.dropEngine(engine);
          this.recordsFailed.add(engine);
          this.requestDraw();
          return;
        }
      } else if (complete && (rec.dirty || this.recordsLast !== rec)) rec.refresh(engine);
      this.recordsLast = rec;
      // Items' pictures: while veiled, all at once; while zooming, only those with none.
      // The view rests once it has not moved for a while: small items are drawn exact then.
      const now = performance.now();
      if (x !== this.recordsCam[0] || y !== this.recordsCam[1] || dev !== this.recordsCam[2]) {
        this.recordsCam = [x, y, dev];
        this.recordsMoved = now;
      }
      // Until a newly opened document is first whole (the splash over it), items are
      // drawn as behind the veil: all at once.
      const covered = !!switching || this.opening;
      const idle = covered || now - this.recordsMoved > REST_MS;
      if (!idle) {
        window.clearTimeout(this.restTimer);
        this.restTimer = window.setTimeout(() => this.requestDraw(), REST_MS + 5);
      }
      if (rec.has(this.page)) rec.draw(engine, this.page, x, y, dev, this.background(), !switching, moving && !covered, covered ? 50 : moving ? 1.5 : 2.5, idle);
    } catch (err) {
      console.error("records frame", err);
    }
    const sharp = whole() && !rec.lacking && rec.has(this.page);
    this.gpuComplete = sharp;
    if (sharp) this.opening = false;
    if (rec.lacking) {
      window.clearTimeout(this.settleTimer);
      this.settleTimer = window.setTimeout(() => this.requestDraw(), 50);
    }
    if (switching) {
      if (sharp || performance.now() - switching.since > SWITCH_MAX_MS) {
        // The new page up in one frame.
        if (rec.has(this.page)) rec.draw(engine, this.page, x, y, dev, this.background(), true);
        this.endSwitch();
      } else {
        window.clearTimeout(this.switchTimer);
        this.switchTimer = window.setTimeout(() => this.requestDraw(), 50);
      }
    }
    this.drawOverlay(pg);
  }

  /** Page `page`'s records are written: what they took of the engine goes with the page,
   * and counts toward what is kept (past the budget, what was shown longest ago goes). */
  private recordsWritten(engine: Engine, page: number): void {
    const feed = feedOf(engine);
    feed?.addLive(page, engine.live() - this.recordsLive);
    if (feed?.keepsPages) keep.fit(engine);
  }

  /** Frame names above top-level frames and the selection outline, as Figma's canvas. */
  private drawOverlay(pg: Page): void {
    if (this.chrome) {
      this.chrome();
      return;
    }
    const ctx = this.ctx;
    const dpr = this.dpr;
    const bg = this.background();
    const lum = 0.2126 * bg[0] + 0.7152 * bg[1] + 0.0722 * bg[2];
    ctx.font = `${11 * dpr}px system-ui, -apple-system, sans-serif`;
    ctx.fillStyle = lum > 0.5 ? "rgba(0,0,0,0.55)" : "rgba(255,255,255,0.6)";
    ctx.textBaseline = "bottom";
    for (const f of pg.frames) {
      if (f.type !== "frame" && f.type !== "component" && f.type !== "component-set" && f.type !== "instance") continue;
      const [x, y, w] = this.screenRect(f.box[0], f.box[1], f.box[2], f.box[3]);
      if (w < 40 * dpr || x > this.canvas.width || x + w < 0 || y < 0 || y > this.canvas.height + 20 * dpr) continue;
      ctx.save();
      ctx.beginPath();
      ctx.rect(x, y - 20 * dpr, w, 20 * dpr);
      ctx.clip();
      ctx.fillText(f.name, x, y - 4 * dpr);
      ctx.restore();
    }
    const sel = this.selected;
    if (sel && sel.page === this.page) {
      const [x, y, w, h] = this.screenRect(sel.box[0], sel.box[1], sel.box[2], sel.box[3]);
      ctx.strokeStyle = "#0d99ff";
      ctx.lineWidth = Math.max(1, dpr);
      ctx.strokeRect(x + 0.5, y + 0.5, w - 1, h - 1);
    }
  }

  // ------------------------------------------------------------ scheduling

  private pump(): void {
    if (!this.pool) return;
    for (const slot of this.pool.slots) {
      if (slot.busy || !slot.ready) continue;
      const job = this.queue.shift();
      if (!job) return;
      void this.run(slot, job);
    }
  }

  private async run(slot: Slot, job: Job): Promise<void> {
    const pool = this.pool;
    if (!pool) return;
    slot.busy = true;
    this.inflight.set(job.key, job);
    const ws = TILE / 2 ** job.level;
    let r: Record<string, unknown> | null = null;
    try {
      r = await pool.call(slot, { type: "tile", page: job.page, x: job.tx * ws, y: job.ty * ws, scale: 2 ** job.level, size: TILE });
    } catch (err) {
      console.error("tile", job.key, err);
    }
    slot.busy = false;
    this.inflight.delete(job.key);
    const bitmap = (r?.bitmap as ImageBitmap | null | undefined) ?? null;
    const stale = this.staleInflight.delete(job.key);
    if (r && job.gen === this.gen) {
      const bytes = bitmap ? TILE * TILE * 4 : 0;
      const old = this.tiles.get(job.key);
      if (old) {
        old.bitmap?.close();
        this.bytes -= old.bytes;
      }
      this.tiles.set(job.key, { key: job.key, bitmap, bytes, used: this.frameNo, stale });
      this.bytes += bytes;
      this.lastMs = r.ms as number;
      this.timings.push({ ms: r.ms as number, level: job.level, zoom: this.cam.z, drawn: r.drawn as number, culled: r.culled as number, empty: !bitmap });
      if (this.timings.length > 4000) this.timings.shift();
      slot.memory = r.memory as number;
      this.evict();
    } else {
      bitmap?.close();
    }
    this.requestDraw();
  }

  /** Drops the least recently drawn tiles past the memory cap (never this frame's). */
  private evict(): void {
    if (this.bytes <= this.cacheBytes) return;
    const list = [...this.tiles.values()].filter((t) => t.used < this.frameNo).sort((a, b) => a.used - b.used);
    for (const t of list) {
      if (this.bytes <= this.cacheBytes * 0.9) break;
      t.bitmap?.close();
      this.bytes -= t.bytes;
      this.tiles.delete(t.key);
    }
  }

  /** Tiles queued or drawing (GPU: CPU layers the frame still waits for). */
  pending(): number {
    // On the GPU: CPU layers on their way, and what the last frame lacked (pages, images
    // being read) or drew as paths for want of glyph masks.
    if (this.usingGpu() && this.records) return (this.gpuComplete ? 0 : 1) + (this.switching ? 1 : 0);
    if (this.usingGpu()) return this.gpu!.stats.pending + (this.gpuComplete ? 0 : 1) + (this.gpu!.stats.glyphsDeferred ? 1 : 0) + (this.switching ? 1 : 0);
    return this.queue.length + this.inflight.size;
  }

  // ------------------------------------------------------------ the chrome's numbers

  private report(): void {
    const now = performance.now();
    // While tiles are pending the numbers change without a frame: report again later.
    if (this.pending() && !this.reportTimer) {
      this.reportTimer = window.setTimeout(() => {
        this.reportTimer = 0;
        this.report();
      }, 250);
    }
    if (now - this.reportAt < 200) return;
    this.reportAt = now;
    const ft = this.frameTimes.filter((t) => t < 250);
    const avg = ft.length ? ft.reduce((a, b) => a + b, 0) / ft.length : 0;
    this.onView({
      zoom: this.cam.z,
      level: this.levelFor(this.devScale()),
      pending: this.pending(),
      tiles: this.tiles.size,
      cacheBytes: this.bytes,
      lastMs: this.lastMs,
      fps: avg ? 1000 / avg : 0,
      drawMs: this.drawMs,
      wasmBytes: (this.pool?.slots ?? []).map((s) => s.memory),
      gpu: this.usingGpu() ? { ...(this.records ? this.records.stats : this.gpu!.stats) } : null,
    });
  }

  // ------------------------------------------------------------ input

  select(hit: Hit | null): void {
    this.selected = hit ? { ...hit, page: this.page } : null;
    this.onSelect(hit);
    this.requestDraw();
  }

  /** The selected node's id, or null. */
  selectedId(): string | null {
    return this.selected?.id ?? null;
  }

  /** Selects what a click at CSS pixel (px, py) lands on: as Figma's click does, or the
   * deepest layer with `deep` (Cmd or Ctrl held). */
  private async pick(px: number, py: number, deep = false): Promise<void> {
    if (!this.doc) return;
    const x = this.cam.x + px / this.cam.z;
    const y = this.cam.y + py / this.cam.z;
    if (this.engine) {
      this.select(this.engine.hitNode(this.page, x, y, deep ? 0 : 1));
      return;
    }
    const pool = this.pool;
    if (!pool) return;
    const r = await pool.call(pool.slots[0], { type: "hit", page: this.page, x, y });
    this.select((r.hit as Hit | null) ?? null);
  }

  private listen(): void {
    const canvas = this.canvas;
    canvas.addEventListener(
      "wheel",
      (e: WheelEvent) => {
        e.preventDefault();
        let dx = e.deltaX;
        let dy = e.deltaY;
        if (e.deltaMode === 1) {
          dx *= 16;
          dy *= 16;
        } else if (e.deltaMode === 2) {
          const [w, h] = this.cssSize();
          dx *= w;
          dy *= h;
        }
        if (e.ctrlKey || e.metaKey) {
          // A pinch arrives as ctrl+wheel with small deltas; a wheel's notches are big.
          this.zoomAt(e.offsetX, e.offsetY, this.cam.z * Math.exp(-clamp(dy, -60, 60) * 0.01));
          return;
        }
        if (e.shiftKey && dx === 0) {
          dx = dy;
          dy = 0;
        }
        this.cam = { ...this.cam, x: this.cam.x + dx / this.cam.z, y: this.cam.y + dy / this.cam.z };
        this.requestDraw();
      },
      { passive: false },
    );

    canvas.addEventListener("pointerdown", (e: PointerEvent) => {
      if (e.button === 1 || (e.button === 0 && (this.spaceDown || this.handTool))) {
        e.preventDefault();
        this.drag = { x: e.clientX, y: e.clientY, id: e.pointerId, click: false };
        canvas.setPointerCapture(e.pointerId);
        canvas.style.cursor = "grabbing";
        return;
      }
      if (e.button === 0) this.drag = { x: e.clientX, y: e.clientY, id: e.pointerId, click: true };
    });

    canvas.addEventListener("pointermove", (e: PointerEvent) => {
      const drag = this.drag;
      if (!drag || drag.id !== e.pointerId) return;
      if (drag.click) {
        if (Math.hypot(e.clientX - drag.x, e.clientY - drag.y) > 4) this.drag = null;
        return;
      }
      this.cam = { ...this.cam, x: this.cam.x - (e.clientX - drag.x) / this.cam.z, y: this.cam.y - (e.clientY - drag.y) / this.cam.z };
      drag.x = e.clientX;
      drag.y = e.clientY;
      this.requestDraw();
    });

    const endDrag = (e: PointerEvent) => {
      const drag = this.drag;
      if (!drag || drag.id !== e.pointerId) return;
      if (drag.click && e.type === "pointerup" && !this.chrome) void this.pick(e.offsetX, e.offsetY, e.metaKey || e.ctrlKey);
      this.drag = null;
      canvas.style.cursor = this.spaceDown || this.handTool ? "grab" : "";
    };
    canvas.addEventListener("pointerup", endDrag);
    canvas.addEventListener("pointercancel", endDrag);
    canvas.addEventListener("auxclick", (e: MouseEvent) => {
      if (e.button === 1) e.preventDefault();
    });

    window.addEventListener("keydown", (e: KeyboardEvent) => {
      const target = e.target as HTMLElement | null;
      if (target && (target.closest("input, textarea, select, [role=listbox], [role=menu]") || target.isContentEditable)) return;
      if (!this.keys()) return;
      const mod = e.metaKey || e.ctrlKey;
      if (e.code === "Space") {
        e.preventDefault();
        if (!this.spaceDown) {
          this.spaceDown = true;
          if (!this.drag) canvas.style.cursor = "grab";
        }
        return;
      }
      if (e.shiftKey && e.code === "Digit1") {
        e.preventDefault();
        this.fit();
      } else if ((e.shiftKey && e.code === "Digit0") || (mod && e.code === "Digit0")) {
        e.preventDefault();
        this.zoomTo(1);
      } else if (e.code === "Equal" || e.code === "NumpadAdd") {
        e.preventDefault();
        this.zoomTo(this.cam.z * 2);
      } else if (e.code === "Minus" || e.code === "NumpadSubtract") {
        e.preventDefault();
        this.zoomTo(this.cam.z / 2);
      } else if (e.code === "Escape") {
        this.select(null);
      }
    });
    const release = () => {
      this.spaceDown = false;
      if (!this.drag) canvas.style.cursor = this.handTool ? "grab" : "";
    };
    window.addEventListener("keyup", (e: KeyboardEvent) => {
      if (e.code === "Space") release();
    });
    window.addEventListener("blur", release);
  }
}
