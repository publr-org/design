// The colour picker beside the Design tab: which colour it edits (a fill or stroke paint,
// a gradient's stop, an effect's colour, the page's background), the colour as hue,
// saturation, brightness and alpha (kept apart so the hue stays on greys), and what a
// pick writes. A drag in the picker is one undo step.

import { Publr } from "publr-jsx";
import { begin, commit, effectsOf, panelPaints, patchEffect, patchPaint, replacePaint, setPageBackground } from "./edits";
import type { Paint, PaintList } from "./edits";
import { colorOf } from "./inspector";
import { onDocChange, shell } from "./store";

export type PickerTarget = PaintList | "effect" | "page";
export type Stop = { at: number; color: unknown };

export const picker = Publr.reactive({
  open: false,
  target: "fills" as PickerTarget,
  /** The paint or effect (panel order). */
  index: 0,
  top: 0,
  left: 0,
  /** "solid", "linear", "radial", "angular", "diamond", "image", "pattern". */
  type: "solid",
  h: 0,
  s: 0,
  v: 0,
  a: 1,
  hex: "000000",
  /** A gradient's stops (as CSS for the bar) and the picked one. */
  stops: [] as { at: number; css: string; index: number }[],
  /** The stops' bar: the gradient over a checkerboard. */
  bar: "",
  stop: 0,
  eyedropper: typeof window !== "undefined" && "EyeDropper" in window,
});

// ------------------------------------------------------------ colour

export function rgbToHsv(r: number, g: number, b: number): [number, number, number] {
  const max = Math.max(r, g, b);
  const min = Math.min(r, g, b);
  const d = max - min;
  let h = 0;
  if (d) {
    if (max === r) h = ((g - b) / d) % 6;
    else if (max === g) h = (b - r) / d + 2;
    else h = (r - g) / d + 4;
    h *= 60;
    if (h < 0) h += 360;
  }
  return [h, max ? d / max : 0, max];
}

export function hsvToRgb(h: number, s: number, v: number): [number, number, number] {
  const f = (n: number) => {
    const k = (n + h / 60) % 6;
    return v - v * s * Math.max(0, Math.min(k, 4 - k, 1));
  };
  return [f(5), f(3), f(1)];
}

const byte = (x: number) =>
  Math.round(Math.max(0, Math.min(1, x)) * 255)
    .toString(16)
    .padStart(2, "0");

export const hexOf = (h: number, s: number, v: number) => hsvToRgb(h, s, v).map(byte).join("");

/** Takes a colour into the picker (the hue kept when the colour has none). */
function take(color: unknown, alpha = 1): void {
  const c = colorOf(color);
  const r = parseInt(c.hex.slice(0, 2), 16) / 255;
  const g = parseInt(c.hex.slice(2, 4), 16) / 255;
  const b = parseInt(c.hex.slice(4, 6), 16) / 255;
  const [h, s, v] = rgbToHsv(r, g, b);
  if (s > 0 && v > 0) picker.h = h;
  picker.s = s;
  picker.v = v;
  picker.a = c.alpha * alpha;
  picker.hex = c.hex;
}

// ------------------------------------------------------------ reading what it edits

function paint(): Paint | null {
  if (picker.target !== "fills" && picker.target !== "strokes") return null;
  return panelPaints(picker.target)[picker.index] ?? null;
}

const stopCss = (s: Stop) => colorOf(s.color).css;

function showStops(stops: Stop[]): void {
  picker.stops = stops.map((s, index) => ({ at: s.at, css: stopCss(s), index }));
  const sorted = [...stops].sort((a, b) => a.at - b.at);
  picker.bar = `linear-gradient(to right, ${sorted.map((s) => `${stopCss(s)} ${s.at * 100}%`).join(", ")}), repeating-conic-gradient(#d4d4d4 0 25%, #ffffff 0 50%) 0 0 / 8px 8px`;
}

/** Reads the colour being edited again (after an undo, or a change elsewhere). */
export function readPicker(): void {
  if (!picker.open) return;
  if (picker.target === "page") {
    take(`#${shell.pageBackgroundHex}`);
    picker.type = "solid";
    return;
  }
  if (picker.target === "effect") {
    const e = effectsOf()[picker.index];
    if (!e) return closePicker();
    take(e.color ?? "#00000040");
    picker.type = "solid";
    return;
  }
  const p = paint();
  if (!p) return closePicker();
  picker.type = p.type;
  if (p.type === "solid") take(p.color, (p.opacity as number | undefined) ?? 1);
  else if (Array.isArray(p.stops)) {
    const stops = p.stops as Stop[];
    showStops(stops);
    if (picker.stop >= stops.length) picker.stop = 0;
    const s = stops[picker.stop];
    if (s) take(s.color);
  }
}

/** Opens the picker for `target` beside the control `el` (left of the right panel). */
export function openPicker(target: PickerTarget, index: number, el: HTMLElement): void {
  if (picker.open && picker.target === target && picker.index === index) {
    closePicker();
    return;
  }
  const r = el.getBoundingClientRect();
  const panel = el.closest("[data-pd-right]")?.getBoundingClientRect();
  picker.target = target;
  picker.index = index;
  picker.stop = 0;
  picker.left = Math.max(8, (panel?.left ?? r.left) - 248 - 8);
  picker.top = Math.max(8, Math.min(r.top - 8, window.innerHeight - 490));
  picker.open = true;
  readPicker();
}

export function closePicker(): void {
  picker.open = false;
}

// ------------------------------------------------------------ writing

const alphaHex = (a: number) => byte(a);

/** Writes the picker's colour where it belongs. */
function write(): void {
  const hex = `#${picker.hex.toLowerCase()}`;
  if (picker.target === "page") setPageBackground(hex);
  else if (picker.target === "effect") patchEffect(picker.index, { color: `${hex}${alphaHex(picker.a)}` });
  else {
    const p = paint();
    if (!p) return;
    if (p.type === "solid") patchPaint(picker.target, picker.index, { color: hex, opacity: Math.round(picker.a * 1000) / 1000 });
    else if (Array.isArray(p.stops)) {
      const stops = (p.stops as Stop[]).map((s, i) => (i === picker.stop ? { ...s, color: `${hex}${alphaHex(picker.a)}` } : s));
      showStops(stops);
      patchPaint(picker.target, picker.index, { stops });
    }
  }
}

/** A pick in the square or on a slider: one step from press to release. */
export function pick(h: number, s: number, v: number, a: number, phase: "start" | "move" | "end"): void {
  if (phase === "start") begin();
  picker.h = h;
  picker.s = s;
  picker.v = v;
  picker.a = a;
  picker.hex = hexOf(h, s, v).toUpperCase();
  if (phase !== "end") write();
  if (phase === "end") commit();
}

export function typedHex(text: string): void {
  let h = text.trim().replace(/^#/, "");
  if (/^[0-9a-f]{3}$/i.test(h)) h = h.replace(/./g, (c) => c + c);
  if (!/^[0-9a-f]{6}$/i.test(h)) return;
  take(`#${h}`, picker.a);
  write();
}

export function typedAlpha(percent: number): void {
  picker.a = percent / 100;
  write();
}

/** The screen's colour under the pointer (the browser's eyedropper). */
export async function eyedrop(): Promise<void> {
  const Ctor = (window as unknown as { EyeDropper?: new () => { open(): Promise<{ sRGBHex: string }> } }).EyeDropper;
  if (!Ctor) return;
  try {
    const r = await new Ctor().open();
    typedHex(r.sRGBHex);
  } catch {
    // Escape: nothing picked.
  }
}

const HANDLES: Record<string, number[][]> = {
  linear: [
    [0.5, 0],
    [0.5, 1],
    [0, 0.5],
  ],
  radial: [
    [0.5, 0.5],
    [1, 0.5],
    [0.5, 1],
  ],
};

/** Solid, or a gradient of the colour to clear (the stops kept between gradients). */
export function setType(type: string): void {
  const p = paint();
  if (!p || p.type === type || (picker.target !== "fills" && picker.target !== "strokes")) return;
  const base = { visible: p.visible, opacity: p.opacity, blend: p.blend };
  let next: Paint;
  if (type === "solid") {
    const first = (p.stops as Stop[] | undefined)?.[0];
    next = { ...base, type: "solid", color: first ? `#${colorOf(first.color).hex.toLowerCase()}` : "#d9d9d9" };
  } else {
    const c = p.type === "solid" ? colorOf(p.color).hex.toLowerCase() : "";
    const stops = Array.isArray(p.stops) ? p.stops : [
      { at: 0, color: `#${c || "000000"}ff` },
      { at: 1, color: `#${c || "000000"}00` },
    ];
    next = { ...base, type, stops, handles: p.handles ?? HANDLES[type === "linear" ? "linear" : "radial"] };
  }
  for (const k of Object.keys(next)) if (next[k] === undefined) delete next[k];
  replacePaint(picker.target, picker.index, next);
  picker.stop = 0;
  readPicker();
}

export function pickStop(i: number): void {
  picker.stop = i;
  readPicker();
}

export function moveStop(i: number, at: number, phase: "start" | "move" | "end"): void {
  if (phase === "start") begin();
  const p = paint();
  if (p && Array.isArray(p.stops) && (picker.target === "fills" || picker.target === "strokes")) {
    const stops = (p.stops as Stop[]).map((s, k) => (k === i ? { ...s, at } : s));
    showStops(stops);
    if (phase !== "end") patchPaint(picker.target, picker.index, { stops });
  }
  if (phase === "end") commit();
}

export function addStop(at: number): void {
  const p = paint();
  if (!p || !Array.isArray(p.stops) || (picker.target !== "fills" && picker.target !== "strokes")) return;
  const stops = (p.stops as Stop[]).slice().sort((a, b) => a.at - b.at);
  const after = stops.findIndex((s) => s.at > at);
  const near = stops[after < 0 ? stops.length - 1 : Math.max(0, after - 1)];
  const list = (p.stops as Stop[]).slice();
  list.push({ at, color: near.color });
  patchPaint(picker.target, picker.index, { stops: list });
  picker.stop = list.length - 1;
  readPicker();
}

export function removeStop(i: number): void {
  const p = paint();
  if (!p || !Array.isArray(p.stops) || p.stops.length <= 2 || (picker.target !== "fills" && picker.target !== "strokes")) return;
  const list = (p.stops as Stop[]).filter((_, k) => k !== i);
  patchPaint(picker.target, picker.index, { stops: list });
  picker.stop = 0;
  readPicker();
}

// The picker follows undo and redo, and closes when the selection changes.
onDocChange((c) => {
  if (c.why === "undo" || c.why === "redo") readPicker();
});
let lastSelection = "";
Publr.effect(() => {
  const now = shell.selection.join(",");
  if (now !== lastSelection) {
    lastSelection = now;
    Publr.untrack(() => closePicker());
  }
});
