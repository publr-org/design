// The panes' shared view: one zoom and offset for every pane (so they stay in step),
// fit and the fixed zooms in device pixels, wheel zoom at the pointer, drag to pan, the
// swipe divider, the flicker timer, the build-up highlight's frame, and the pixel
// inspector reading both images under the pointer.
import { currentItem, imageUrl, version } from "./data";
import { panesHost, state } from "./store";

const dpr = window.devicePixelRatio || 1;

/** The zoom (image pixels to CSS pixels) and the image's offset in the pane. */
const view = { z: 1, tx: 0, ty: 0, fit: true };
let swipeFrac = 0.5;
let flickerTimer = 0;
/** The build-up's last node, in image pixels, while one is shown. */
let highlight: [number, number, number, number] | null = null;

function firstPane(): HTMLElement | null {
  return (panesHost.current as HTMLElement | null)?.querySelector<HTMLElement>("[data-pane]") ?? null;
}

/** After the panes are drawn for a new mode or export: fit, or keep the view. */
export function relayout(refit: boolean): void {
  if (refit) view.fit = true;
  requestAnimationFrame(() => (view.fit ? fit() : applyView()));
}

export function fit(): void {
  const p = firstPane();
  const it = currentItem();
  if (!p || !it) return;
  const w = p.clientWidth;
  const h = p.clientHeight;
  const pad = 16;
  const z = Math.min((w - pad * 2) / it.width, (h - pad * 2) / it.height);
  view.z = z;
  view.tx = (w - it.width * z) / 2;
  view.ty = Math.max(pad, (h - it.height * z) / 2);
  view.fit = true;
  applyView();
}

/** Zooms about a point in the pane (its centre by default). */
export function zoomTo(z: number, cx?: number, cy?: number): void {
  const p = firstPane();
  if (!p) return;
  const x = cx ?? p.clientWidth / 2;
  const y = cy ?? p.clientHeight / 2;
  const next = Math.min(64, Math.max(0.01, z));
  view.tx = x - (x - view.tx) * (next / view.z);
  view.ty = y - (y - view.ty) * (next / view.z);
  view.z = next;
  view.fit = false;
  applyView();
}

/** Whether the view follows the pane's size (a resize refits). */
export const isFitted = (): boolean => view.fit;

/** A zoom button: `fit`, or a ratio of image pixels to device pixels. */
export function zoomPreset(key: string): void {
  if (key === "fit") fit();
  else zoomTo(Number(key) / dpr);
}

export function applyView(): void {
  state.transform = `translate(${view.tx}px, ${view.ty}px) scale(${view.z})`;
  // Past one device pixel per image pixel the images stay crisp.
  state.pixelated = view.z * dpr > 1.01;
  state.zoomLabel = `${Math.round(view.z * dpr * 100)}%`;
  state.zoomKey = view.fit ? "fit" : (["1", "2", "4"].find((k) => Math.abs(view.z * dpr - Number(k)) < 1e-6) ?? "");
  if (state.mode === "swipe") {
    const p = firstPane();
    const x = swipeFrac * (p?.clientWidth ?? 0);
    state.dividerLeft = `${x}px`;
    state.oursClip = `inset(0 0 0 ${Math.max(0, (x - view.tx) / view.z)}px)`;
  }
  paintHighlight();
}

// ---- pointer ----

export function wheel(event: WheelEvent): void {
  event.preventDefault();
  const r = (event.currentTarget as HTMLElement).getBoundingClientRect();
  const k = event.ctrlKey ? 0.01 : 0.0015;
  zoomTo(view.z * Math.exp(-event.deltaY * k), event.clientX - r.left, event.clientY - r.top);
}

export function panStart(event: MouseEvent): void {
  if (event.button !== 0) return;
  event.preventDefault();
  const pane = event.currentTarget as HTMLElement;
  pane.dataset.dragging = "";
  let lx = event.clientX;
  let ly = event.clientY;
  const move = (ev: MouseEvent) => {
    view.tx += ev.clientX - lx;
    view.ty += ev.clientY - ly;
    lx = ev.clientX;
    ly = ev.clientY;
    view.fit = false;
    applyView();
  };
  const up = () => {
    delete pane.dataset.dragging;
    removeEventListener("mousemove", move);
    removeEventListener("mouseup", up);
  };
  addEventListener("mousemove", move);
  addEventListener("mouseup", up);
}

export function dividerStart(event: MouseEvent): void {
  event.stopPropagation();
  event.preventDefault();
  const pane = (event.currentTarget as HTMLElement).closest<HTMLElement>("[data-pane]");
  if (!pane) return;
  const rect = pane.getBoundingClientRect();
  const move = (ev: MouseEvent) => {
    swipeFrac = Math.min(1, Math.max(0, (ev.clientX - rect.left) / rect.width));
    applyView();
  };
  const up = () => {
    removeEventListener("mousemove", move);
    removeEventListener("mouseup", up);
  };
  addEventListener("mousemove", move);
  addEventListener("mouseup", up);
}

export function hover(event: MouseEvent): void {
  const r = (event.currentTarget as HTMLElement).getBoundingClientRect();
  inspect(Math.floor((event.clientX - r.left - view.tx) / view.z), Math.floor((event.clientY - r.top - view.ty) / view.z));
}

export function leave(): void {
  state.inspect = { ...state.inspect, state: "idle" };
}

// ---- flicker ----

export function startFlicker(): void {
  stopFlicker();
  state.flickerRef = true;
  flickerTimer = window.setInterval(() => {
    if (!state.flickerPaused) state.flickerRef = !state.flickerRef;
  }, 500);
}

export function stopFlicker(): void {
  if (flickerTimer) clearInterval(flickerTimer);
  flickerTimer = 0;
}

export function toggleFlickerPause(): void {
  state.flickerPaused = !state.flickerPaused;
}

// ---- build-up highlight ----

/** Frames the node a build-up step drew; null hides the frame. */
export function setHighlight(bounds: [number, number, number, number] | null): void {
  highlight = bounds;
  paintHighlight();
}

function paintHighlight(): void {
  const b = highlight;
  if (!b || b[2] <= b[0] || b[3] <= b[1]) {
    state.hlShown = false;
    return;
  }
  // The frame keeps 2 screen pixels at any zoom.
  state.hlShown = true;
  state.hlStyle = `left:${b[0]}px;top:${b[1]}px;width:${Math.max(1, b[2] - b[0])}px;height:${Math.max(1, b[3] - b[1])}px;border-width:${2 / view.z}px`;
}

// ---- pixel inspector ----

type Pixels = { file: string; v: number; ctx: CanvasRenderingContext2D | null };
let pixels: Partial<Record<"ref" | "ours", Pixels>> = {};

/** Drops the decoded images (the server restarted). */
export function forgetPixels(): void {
  pixels = {};
}

/** The image's pixels once decoded; starts decoding and answers null until then. */
function pixelSource(kind: "ref" | "ours", file: string): CanvasRenderingContext2D | null {
  const have = pixels[kind];
  if (have && have.file === file && have.v === version()) return have.ctx;
  const entry: Pixels = { file, v: version(), ctx: null };
  pixels[kind] = entry;
  const image = new Image();
  image.onload = () => {
    const canvas = document.createElement("canvas");
    canvas.width = image.naturalWidth;
    canvas.height = image.naturalHeight;
    const ctx = canvas.getContext("2d", { willReadFrequently: true });
    if (!ctx) return;
    ctx.drawImage(image, 0, 0);
    entry.ctx = ctx;
  };
  image.src = imageUrl(kind, file);
  return null;
}

function rgba(ctx: CanvasRenderingContext2D | null, x: number, y: number): number[] | null {
  if (!ctx) return null;
  const d = ctx.getImageData(x, y, 1, 1).data;
  return [d[0], d[1], d[2], d[3]];
}

const premul = (p: number[]): number[] => p.slice(0, 3).map((c) => Math.round((c * p[3]) / 255)).concat(p[3]);

function inspect(x: number, y: number): void {
  const it = currentItem();
  if (!it) return;
  const at = `${x}, ${y}`;
  if (x < 0 || y < 0 || x >= it.width || y >= it.height) {
    state.inspect = { ...state.inspect, state: "outside", at };
    return;
  }
  const a = rgba(pixelSource("ref", it.file), x, y);
  const b = rgba(pixelSource("ours", it.file), x, y);
  let diff = "";
  let diffOk = true;
  if (a && b) {
    const pa = premul(a);
    const pb = premul(b);
    const d = Math.max(...pa.map((v, i) => Math.abs(v - pb[i])));
    diff = String(d);
    diffOk = d <= 2;
  }
  const color = (p: number[] | null) => (p ? `rgba(${p[0]},${p[1]},${p[2]},${p[3] / 255})` : "");
  state.inspect = {
    state: "pixel",
    at,
    figma: a ? a.join(",") : "",
    figmaColor: color(a),
    ours: b ? b.join(",") : "",
    oursColor: color(b),
    diff,
    diffOk,
  };
}
