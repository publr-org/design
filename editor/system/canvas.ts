// The design system canvas: PublrEngine draws the scene (scene.ts) on the GPU with the
// viewer's own Stage (pan, zoom, the same camera as the canvas beside), an engine of
// its own on this thread holds the document and edits it (the viewer's Editing: one
// step per change, Cmd+Z), and a 2D canvas above draws the marks in Design mode's look
// (2 px hover, 1 px selection, the frame names, the insertion line). Nothing is drawn
// freely: a press picks an item, a section or an "+ Add" chip; a drag reorders items
// inside their list, or carries one out onto the canvas beside.
//
// Glue, not UI.

import { Editing } from "../viewer/edit";
import type { Engine } from "../viewer/engine";
import { GpuCanvas } from "../viewer/gpu";
import { startMainEngine, takeEarlyEngine } from "../viewer/loader";
import { Stage } from "../viewer/stage";
import { BLUE, pill } from "../design/tools/marks";
import type { Painter } from "../design/tools/marks";
import { addFromChip, carryOut, carryOver, reorder } from "./actions";
import { completeDoc, SECTION_OF } from "./model";
import type { Doc, ItemKind, ItemRef, SectionKey } from "./model";
import { buildScene, clean, diff, itemId, PAGE_ID, sectionId } from "./scene";
import type { Scene, SceneContext } from "./scene";
import { attachCanvas, failed, opened, restored, selectItem, selectSection, sys } from "./store";

type Box = [number, number, number, number];
type Geo = { id: string; ctm: number[]; size: [number, number] };

const BACKGROUND = "#f5f5f5";
const encoder = new TextEncoder();
const DRAG_PX = 3;
/** Lists whose items a drag reorders. */
const ORDERED = new Set<ItemKind>(["color", "spacing", "radius", "shadow", "font", "icon", "container", "role", "type"]);

/** What the page keeps as host data: the document. */
const dataOf = (doc: Doc) => ({ publr: { designSystem: doc.system, primitives: doc.primitives } });

function boxOf(g: Geo): Box {
  const m = g.ctm;
  const [w, h] = g.size;
  const xs = [m[4], m[0] * w + m[4], m[2] * h + m[4], m[0] * w + m[2] * h + m[4]];
  const ys = [m[5], m[1] * w + m[5], m[3] * h + m[5], m[1] * w + m[3] * h + m[5]];
  return [Math.min(...xs), Math.min(...ys), Math.max(...xs), Math.max(...ys)];
}

const inside = (b: Box, x: number, y: number) => x >= b[0] && x <= b[2] && y >= b[1] && y <= b[3];
const area = (b: Box) => (b[2] - b[0]) * (b[3] - b[1]);

type Press = { x: number; y: number; px: number; py: number; item: ItemRef | null; chip: ItemKind | null; dragging: "" | "reorder" | "out"; slot: number; id: number };

export class DsCanvas {
  readonly host: HTMLElement;
  readonly stage: Stage;
  private gpuEl: HTMLCanvasElement;
  private marks: HTMLCanvasElement;
  private mctx: CanvasRenderingContext2D;
  private dpr = 1;
  engine: Engine | null = null;
  editing: Editing | null = null;
  private scene: Scene | null = null;
  private ctx: SceneContext | null = null;
  /** Page boxes of the items, sections, chips and columns. */
  private boxes = new Map<string, Box>();
  private hover = "";
  private press: Press | null = null;
  private narrowed: SectionKey | null = null;
  /** Fitted once while shown (a canvas opened hidden fits when it shows). */
  private fitted = false;
  /** A drag from the canvas beside is over this section (or this block's tile). */
  private dropTarget: { section: SectionKey; item: string } | null = null;
  private scheduled = false;
  private spaceDown = false;
  /** The selection a step recorded, put back by undo and redo. */
  private restoredIds: string[] = [];

  constructor(host: HTMLElement) {
    this.host = host;
    this.gpuEl = document.createElement("canvas");
    this.gpuEl.style.cssText = "position:absolute;inset:0;width:100%;height:100%;display:block";
    host.append(this.gpuEl);
    this.stage = new Stage(host, 64 * 1048576);
    this.stage.canvas.dataset.pdSystemCanvas = "";
    this.marks = document.createElement("canvas");
    this.marks.style.cssText = "position:absolute;inset:0;width:100%;height:100%;display:block;pointer-events:none";
    host.append(this.marks);
    this.mctx = this.marks.getContext("2d")!;
    this.stage.chrome = () => this.draw();
    this.stage.keys = () => sys.focus === "system";
    new ResizeObserver(() => this.resize()).observe(this.marks);
    this.resize();
    this.listen();
    attachCanvas(this);
  }

  // ------------------------------------------------------------ the document

  /** Draws `doc`: the engine, the GPU, the scene laid out, the history empty. */
  async start(doc: Doc, blocks: SceneContext["blocks"], name: string, sample: string): Promise<void> {
    try {
      const engine = await (takeEarlyEngine() ?? startMainEngine());
      const gpu = await GpuCanvas.create(this.gpuEl, engine);
      if (!gpu) throw new Error("This browser cannot draw with WebGPU.");
      this.engine = engine;
      this.stage.attachGpu(gpu, engine);
      // The faces here, for the specimens and the font picker.
      const faces: Record<string, [number, string][]> = {};
      for (const f of engine.fontFaces()) if (!f.italic) (faces[f.family] ??= []).push([f.weight, f.style]);
      for (const k of Object.keys(faces)) faces[k].sort((a, b) => a[0] - b[0]);
      sys.faces = faces;
      sys.blocks = blocks;
      const near = (family: string, weight: number) => {
        const list = faces[family] ?? [];
        return list.find((f) => f[0] === weight) ?? [...list].sort((a, b) => Math.abs(a[0] - weight) - Math.abs(b[0] - weight))[0];
      };
      this.ctx = {
        face: (family, weight) => near(family, weight)?.[1] ?? "",
        weights: (family) => [...new Set((faces[family] ?? []).map((f) => f[0]))],
        blocks,
        sample,
        name,
      };
      const scene = buildScene(doc, this.ctx);
      // Laid out once by the engine's own auto layout (inserting runs it), then read
      // again as a document: the canvas opens with nothing to undo.
      const empty = { pubd: 2, name: `${name} design system`, pages: [{ id: PAGE_ID, type: "page", name: "Design system", background: BACKGROUND, data: dataOf(doc) }] };
      engine.loadPubd(encoder.encode(JSON.stringify(empty)));
      engine.editApply(scene.roots.map((n, i) => ({ op: "insert", parent: PAGE_ID, index: i, node: clean(n) })));
      const laid = engine.pubdJson();
      engine.close();
      engine.gpuForget();
      engine.loadPubd(laid);
      this.scene = scene;
      const ed = new Editing(this.stage);
      ed.attach(engine, null, "");
      ed.keys = () => sys.focus === "system";
      ed.selectionSource = () => (sys.selected ? [itemId(sys.selected)] : []);
      ed.restoreSelection = (ids) => (this.restoredIds = ids);
      ed.onChange((_out, why) => {
        if (why === "undo" || why === "redo" || why === "cancel") this.readBack();
      });
      this.editing = ed;
      this.stage.open(engine.pages());
      this.measure();
      this.narrow(sys.section === "overview" ? null : sys.section, true);
      opened();
      (window as unknown as { pdSystem?: DsCanvas }).pdSystem = this;
    } catch (err) {
      console.error("design system canvas", err);
      failed(err instanceof Error ? err.message : String(err));
    }
  }

  /** Draws the next document as one step: the data on the page and the scene's changes. */
  apply(next: Doc, selected: ItemRef | null): void {
    if (!this.editing || !this.scene || !this.ctx) return;
    const scene = buildScene(next, this.ctx);
    const changes = [{ op: "set", node: PAGE_ID, props: { data: dataOf(next) } }, ...diff(this.scene.roots, scene.roots)];
    this.scene = scene;
    void selected;
    try {
      this.editing.edit(changes);
    } catch (err) {
      console.error("design system: the change did not apply", err, changes);
    }
    this.measure();
    if (selected) this.reveal(itemId(selected));
    this.request();
  }

  /** Pans so node `id` shows whole, when it is out of view (a new item at the end of a
   * long list). */
  reveal(id: string): void {
    const b = this.boxes.get(id);
    if (!b) return;
    const v = this.stage.cam;
    const [cw, ch] = this.cssSize();
    const pad = 40 / v.z;
    const x0 = v.x;
    const y0 = v.y;
    const x1 = v.x + cw / v.z;
    const y1 = v.y + ch / v.z;
    if (b[0] >= x0 && b[2] <= x1 && b[1] >= y0 && b[3] <= y1) return;
    const x = b[0] < x0 ? b[0] - pad : b[2] > x1 ? b[2] + pad - cw / v.z : v.x;
    const y = b[1] < y0 ? b[1] - pad : b[3] > y1 ? b[3] + pad - ch / v.z : v.y;
    this.stage.setCamera({ ...v, x, y });
  }

  /** After undo or redo: the page's data is the document again; the scene is the one it
   * draws (the engine put back exactly that). */
  private readBack(): void {
    if (!this.engine || !this.ctx) return;
    const page = this.engine.nodeInfo(PAGE_ID).node as { data?: unknown };
    const data = (typeof page.data === "string" ? JSON.parse(page.data) : page.data) as { publr?: { designSystem?: Doc["system"]; primitives?: Doc["primitives"] } } | undefined;
    if (!data?.publr?.designSystem) {
      console.error("design system: the page holds no data", page.data);
      return;
    }
    const doc = completeDoc({ system: data.publr.designSystem, primitives: data.publr.primitives });
    this.scene = buildScene(doc, this.ctx);
    this.measure();
    const id = this.restoredIds[0] ?? "";
    restored(doc, this.scene.items.get(id) ?? null);
    this.request();
  }

  /** Where node `id` (an item, a section, a chip) is on screen, in client pixels (for
   * tests driving real input). */
  clientBox(id: string): [number, number, number, number] | null {
    const b = this.boxes.get(id);
    if (!b) return null;
    const r = this.marks.getBoundingClientRect();
    const [x0, y0] = this.toScreen(b[0], b[1]);
    const [x1, y1] = this.toScreen(b[2], b[3]);
    return [r.left + x0, r.top + y0, r.left + x1, r.top + y1];
  }

  hasItem(ref: ItemRef): boolean {
    return !!this.scene?.items.has(itemId(ref));
  }

  /** Where everything is on the page, after each change. */
  private measure(): void {
    const s = this.scene;
    const e = this.engine;
    if (!s || !e) return;
    const ids = [...s.items.keys(), ...s.sections.keys(), ...s.chips.keys(), ...s.roots.map((r) => r.id)];
    const geos = e.canvasNodes<Geo>(ids);
    this.boxes.clear();
    geos.forEach((g, i) => g && this.boxes.set(ids[i], boxOf(g)));
  }

  // ------------------------------------------------------------ the view

  /** Narrows the canvas to one section (null: the whole system), fitting it. */
  narrow(key: SectionKey | null, fit: boolean): void {
    this.narrowed = key;
    if (!fit) return this.request();
    if (this.cssSize()[0] > 1) this.fitted = true;
    const box = key ? this.boxes.get(sectionId(key)) : this.all();
    if (box) {
      const pad = key ? 56 : 80;
      const [w] = this.cssSize();
      const z = Math.min(1, (w - pad * 2) / (box[2] - box[0]));
      if (key) {
        // The section's width at the top of the view (a long section scrolls).
        this.stage.setCamera({ z, x: (box[0] + box[2]) / 2 - w / 2 / z, y: box[1] - pad / z });
      } else this.stage.showRect(box[0], box[1], box[2], box[3], pad);
    }
    this.request();
  }

  private all(): Box | null {
    let b: Box | null = null;
    for (const r of this.scene?.roots ?? []) {
      const x = this.boxes.get(r.id);
      if (x) b = b ? [Math.min(b[0], x[0]), Math.min(b[1], x[1]), Math.max(b[2], x[2]), Math.max(b[3], x[3])] : [...x];
    }
    return b;
  }

  private cssSize(): [number, number] {
    const r = this.marks.getBoundingClientRect();
    return [r.width, r.height];
  }

  private resize(): void {
    this.dpr = window.devicePixelRatio || 1;
    const r = this.marks.getBoundingClientRect();
    // First drawn while hidden (opened on a file's tab): fitted once it shows.
    if (!this.fitted && r.width > 1 && this.scene) requestAnimationFrame(() => this.narrow(this.narrowed, true));
    this.marks.width = Math.max(1, Math.round(r.width * this.dpr));
    this.marks.height = Math.max(1, Math.round(r.height * this.dpr));
    this.draw();
  }

  /** The camera as the stage draws it (whole device pixels). */
  private view(): { x: number; y: number; z: number } {
    const c = this.stage.cam;
    const dev = c.z * this.dpr;
    return { x: Math.round(c.x * dev) / dev, y: Math.round(c.y * dev) / dev, z: c.z };
  }

  private toScreen(x: number, y: number): [number, number] {
    const v = this.view();
    return [(x - v.x) * v.z, (y - v.y) * v.z];
  }

  /** A client point to a page point. */
  toPage(clientX: number, clientY: number): [number, number] {
    const r = this.marks.getBoundingClientRect();
    const v = this.view();
    return [v.x + (clientX - r.left) / v.z, v.y + (clientY - r.top) / v.z];
  }

  /** Whether a client point is over this canvas (and not over what floats on it: the
   * reference drawn picture-in-picture, the selector). */
  over(clientX: number, clientY: number): boolean {
    const r = this.host.getBoundingClientRect();
    if (!(clientX >= r.left && clientX <= r.right && clientY >= r.top && clientY <= r.bottom)) return false;
    const top = document.elementFromPoint(clientX, clientY);
    return !top || top === this.host || this.host.contains(top) || !!top.closest("[data-pd-carry]");
  }

  request(): void {
    if (this.scheduled) return;
    this.scheduled = true;
    requestAnimationFrame(() => {
      this.scheduled = false;
      this.draw();
    });
  }

  // ------------------------------------------------------------ what is where

  /** The innermost item at a page point (`kinds`: only those). */
  itemAt(x: number, y: number, kinds?: Set<ItemKind>): { id: string; ref: ItemRef } | null {
    let best: { id: string; ref: ItemRef; a: number } | null = null;
    for (const [id, ref] of this.scene?.items ?? []) {
      if (kinds && !kinds.has(ref.kind)) continue;
      const b = this.boxes.get(id);
      if (!b || !inside(b, x, y)) continue;
      if (this.narrowed && SECTION_OF[ref.kind] !== this.narrowed) continue;
      const a = area(b);
      if (!best || a < best.a) best = { id, ref, a };
    }
    return best;
  }

  chipAt(x: number, y: number): { id: string; kind: ItemKind } | null {
    for (const [id, kind] of this.scene?.chips ?? []) {
      const b = this.boxes.get(id);
      if (b && inside(b, x, y) && (!this.narrowed || SECTION_OF[kind] === this.narrowed)) return { id, kind };
    }
    return null;
  }

  sectionAt(x: number, y: number): SectionKey | null {
    for (const [id, key] of this.scene?.sections ?? []) {
      const b = this.boxes.get(id);
      if (b && inside(b, x, y) && (!this.narrowed || key === this.narrowed)) return key;
    }
    return null;
  }

  /** A drag from beside: what it is over (a section, and an item of it), highlighted. */
  dropAt(clientX: number, clientY: number): { section: SectionKey; item: ItemRef | null } | null {
    const [x, y] = this.toPage(clientX, clientY);
    const section = this.sectionAt(x, y);
    const item = section ? this.itemAt(x, y) : null;
    const next = section ? { section, item: item?.id ?? "" } : null;
    if (JSON.stringify(next) !== JSON.stringify(this.dropTarget)) {
      this.dropTarget = next;
      this.request();
    }
    return section ? { section, item: item?.ref ?? null } : null;
  }

  clearDrop(): void {
    this.dropTarget = null;
    this.request();
  }

  // ------------------------------------------------------------ the marks

  private painter(): Painter {
    return { ctx: this.mctx, dpr: this.dpr, screen: (x, y) => this.toScreen(x, y), zoom: () => this.view().z };
  }

  private rectOf(b: Box): [number, number, number, number] {
    const [x0, y0] = this.toScreen(b[0], b[1]);
    const [x1, y1] = this.toScreen(b[2], b[3]);
    return [Math.round(x0) + 0.5, Math.round(y0) + 0.5, Math.round(x1 - x0), Math.round(y1 - y0)];
  }

  private outline(b: Box | undefined, width: number, color = BLUE): void {
    if (!b) return;
    const ctx = this.mctx;
    const [x, y, w, h] = this.rectOf(b);
    ctx.strokeStyle = color;
    ctx.lineWidth = width;
    ctx.strokeRect(x, y, w, h);
  }

  draw(): void {
    const ctx = this.mctx;
    const d = this.dpr;
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.clearRect(0, 0, this.marks.width, this.marks.height);
    ctx.setTransform(d, 0, 0, d, 0, 0);
    if (!this.scene) return;
    const [cw, ch] = this.cssSize();
    // Narrowed: the section alone; the rest is page.
    if (this.narrowed) {
      const b = this.boxes.get(sectionId(this.narrowed));
      if (b) {
        const [x, y, w, h] = this.rectOf(b);
        ctx.fillStyle = BACKGROUND;
        ctx.fillRect(0, 0, cw, Math.max(0, y - 0.5));
        ctx.fillRect(0, y + h - 0.5, cw, ch);
        ctx.fillRect(0, y - 0.5, Math.max(0, x - 0.5), h);
        ctx.fillRect(x + w - 0.5, y - 0.5, cw, h);
        this.clamp(b);
      }
    } else {
      // The columns' names above them, as frame names show.
      ctx.font = `11px "PD Inter", Inter, system-ui, sans-serif`;
      ctx.fillStyle = "rgba(0,0,0,0.55)";
      ctx.textBaseline = "bottom";
      for (const r of this.scene.roots) {
        const b = this.boxes.get(r.id);
        if (!b) continue;
        const [x, y] = this.toScreen(b[0], b[1]);
        const [x1] = this.toScreen(b[2], b[3]);
        ctx.save();
        ctx.beginPath();
        ctx.rect(x, y - 24, Math.max(0, x1 - x), 24);
        ctx.clip();
        ctx.fillText(String(r.name ?? ""), x, y - 6);
        ctx.restore();
      }
    }
    const p = this.painter();
    if (this.dropTarget) {
      const b = this.boxes.get(sectionId(this.dropTarget.section));
      if (b) {
        const [x, y, w, h] = this.rectOf(b);
        ctx.fillStyle = "rgba(13,153,255,0.06)";
        ctx.fillRect(x, y, w, h);
        this.outline(b, 2);
      }
      if (this.dropTarget.item) this.outline(this.boxes.get(this.dropTarget.item), 2);
    }
    const sel = sys.selected ? itemId(sys.selected) : "";
    if (this.hover && this.hover !== sel && !this.press?.dragging) this.outline(this.boxes.get(this.hover), 2);
    if (sys.selectedSection && !sel) this.outline(this.boxes.get(sectionId(sys.selectedSection)), 1);
    if (sel) {
      const b = this.boxes.get(sel);
      this.outline(b, 1);
      if (b && sys.selected) {
        const [x, y, w, h] = this.rectOf(b);
        const label = this.scene.items.get(sel)?.key ?? "";
        if (w > 30) pill(p, label.length > 40 ? `${label.slice(0, 39)}…` : label, x + w / 2, y + h + 14, BLUE);
      }
    }
    // A reorder: the insertion line where the item goes.
    const pr = this.press;
    if (pr?.dragging === "reorder" && pr.item) {
      const line = this.slotLine(pr.item, pr.slot);
      if (line) {
        ctx.strokeStyle = BLUE;
        ctx.lineWidth = 2;
        ctx.beginPath();
        const [ax, ay] = this.toScreen(line[0], line[1]);
        const [bx, by] = this.toScreen(line[2], line[3]);
        ctx.moveTo(ax, ay);
        ctx.lineTo(bx, by);
        ctx.stroke();
      }
    }
  }

  /** Keeps a narrowed section in view: the camera stops at its edges. */
  private clamp(b: Box): void {
    const v = this.stage.cam;
    const [cw, ch] = this.cssSize();
    const vw = cw / v.z;
    const vh = ch / v.z;
    const pad = 56 / v.z;
    const fitX = b[2] - b[0] + 2 * pad <= vw;
    const fitY = b[3] - b[1] + 2 * pad <= vh;
    const x = fitX ? Math.min(Math.max(v.x, b[2] + pad - vw), b[0] - pad) : Math.min(Math.max(v.x, b[0] - pad), b[2] + pad - vw);
    const y = fitY ? Math.min(Math.max(v.y, b[3] + pad - vh), b[1] - pad) : Math.min(Math.max(v.y, b[1] - pad), b[3] + pad - vh);
    if (Math.abs(x - v.x) > 0.01 || Math.abs(y - v.y) > 0.01) this.stage.setCamera({ ...v, x, y });
  }

  // ------------------------------------------------------------ reordering

  /** The items of the list `ref` is in, in order, with their boxes. */
  private siblings(ref: ItemRef): { ref: ItemRef; box: Box }[] {
    const out: { ref: ItemRef; box: Box }[] = [];
    for (const [id, r] of this.scene?.items ?? []) if (r.kind === ref.kind && this.boxes.has(id)) out.push({ ref: r, box: this.boxes.get(id)! });
    return out;
  }

  /** Whether the list lays out in a row (wrapping) rather than a column. */
  private rowList(kind: ItemKind): boolean {
    return kind === "color" || kind === "radius" || kind === "shadow" || kind === "font" || kind === "icon" || kind === "role";
  }

  /** The slot (an index among the siblings, before which it goes) nearest a point. */
  private slotAt(ref: ItemRef, x: number, y: number): number {
    const list = this.siblings(ref);
    if (!this.rowList(ref.kind)) {
      let slot = list.length;
      for (let i = 0; i < list.length; i++)
        if (y < (list[i].box[1] + list[i].box[3]) / 2) {
          slot = i;
          break;
        }
      return slot;
    }
    // Rows that wrap: the line the point is on, then the place in it.
    let best = list.length;
    let bestD = Infinity;
    list.forEach((s, i) => {
      const cy = (s.box[1] + s.box[3]) / 2;
      const dy = y < s.box[1] ? s.box[1] - y : y > s.box[3] ? y - s.box[3] : 0;
      const before = x < (s.box[0] + s.box[2]) / 2;
      const dx = Math.abs(x - (before ? s.box[0] : s.box[2]));
      const dist = dy * 4 + dx + Math.abs(y - cy) * 0.01;
      if (dist < bestD) {
        bestD = dist;
        best = before ? i : i + 1;
      }
    });
    return best;
  }

  private slotLine(ref: ItemRef, slot: number): [number, number, number, number] | null {
    const list = this.siblings(ref);
    if (!list.length) return null;
    if (!this.rowList(ref.kind)) {
      const y = slot < list.length ? list[slot].box[1] - 6 : list[list.length - 1].box[3] + 6;
      const b = list[Math.min(slot, list.length - 1)].box;
      return [b[0], y, b[2], y];
    }
    const at = slot < list.length ? list[slot].box : list[list.length - 1].box;
    const x = slot < list.length ? at[0] - 10 : at[2] + 10;
    return [x, at[1], x, at[3]];
  }

  // ------------------------------------------------------------ input

  private listen(): void {
    const c = this.stage.canvas;
    window.addEventListener("keydown", (e) => {
      if (e.code === "Space") this.spaceDown = true;
    });
    window.addEventListener("keyup", (e) => {
      if (e.code === "Space") this.spaceDown = false;
    });
    c.addEventListener("pointermove", (e: PointerEvent) => {
      if (this.press) return;
      const [x, y] = this.toPage(e.clientX, e.clientY);
      const chip = this.chipAt(x, y);
      const item = chip ? null : this.itemAt(x, y);
      const next = chip?.id ?? item?.id ?? "";
      c.style.cursor = this.spaceDown || this.stage.handTool ? c.style.cursor : chip ? "pointer" : "";
      if (next !== this.hover) {
        this.hover = next;
        this.request();
      }
    });
    c.addEventListener("pointerleave", () => {
      if (this.hover && !this.press) {
        this.hover = "";
        this.request();
      }
    });
    c.addEventListener("pointerdown", (e: PointerEvent) => {
      sys.focus = "system";
      if (e.button !== 0 || this.spaceDown || this.stage.handTool || !this.scene) return;
      const [x, y] = this.toPage(e.clientX, e.clientY);
      const chip = this.chipAt(x, y);
      const item = chip ? null : this.itemAt(x, y);
      if (item) selectItem(item.ref);
      else if (!chip) selectSection(this.sectionAt(x, y) ?? "");
      this.press = { x, y, px: e.clientX, py: e.clientY, item: item?.ref ?? null, chip: chip?.kind ?? null, dragging: "", slot: -1, id: e.pointerId };
      window.addEventListener("pointermove", this.onMove);
      window.addEventListener("pointerup", this.onUp);
      window.addEventListener("pointercancel", this.onCancel);
    });
  }

  private onMove = (e: PointerEvent): void => {
    const pr = this.press;
    if (!pr || e.pointerId !== pr.id) return;
    if (!pr.dragging) {
      if (!pr.item || Math.hypot(e.clientX - pr.px, e.clientY - pr.py) < DRAG_PX) return;
      pr.dragging = "reorder";
      this.hover = "";
    }
    if (this.over(e.clientX, e.clientY)) {
      if (pr.dragging === "out") carryOut(null, e);
      pr.dragging = ORDERED.has(pr.item!.kind) ? "reorder" : "out";
      if (pr.dragging === "reorder") {
        const [x, y] = this.toPage(e.clientX, e.clientY);
        pr.slot = this.slotAt(pr.item!, x, y);
      }
    } else {
      pr.dragging = "out";
      carryOut(pr.item, e);
    }
    this.request();
  };

  private onUp = (e: PointerEvent): void => {
    const pr = this.press;
    this.release();
    if (!pr) return;
    if (pr.chip && !pr.dragging) {
      const [x, y] = this.toPage(e.clientX, e.clientY);
      if (this.chipAt(x, y)?.kind === pr.chip) addFromChip(pr.chip);
    } else if (pr.dragging === "reorder" && pr.item && this.over(e.clientX, e.clientY)) {
      const list = this.siblings(pr.item);
      const from = list.findIndex((s) => s.ref.key === pr.item!.key);
      if (from >= 0 && pr.slot >= 0) {
        const to = pr.slot > from ? pr.slot - 1 : pr.slot;
        if (to !== from) reorder(pr.item, from, to);
      }
    } else if (pr.dragging === "out" && pr.item) {
      carryOver(pr.item, e);
    }
    this.request();
  };

  private onCancel = (): void => {
    if (this.press?.dragging === "out") carryOut(null, null);
    this.release();
    this.request();
  };

  private release(): void {
    window.removeEventListener("pointermove", this.onMove);
    window.removeEventListener("pointerup", this.onUp);
    window.removeEventListener("pointercancel", this.onCancel);
    this.press = null;
  }
}
