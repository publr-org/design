// How far a file's opening has come, for the splash over the window (design/Splash.ptsx).
// The opening is made of steps, each with a share of the bar: the engine (its WASM and
// the fonts, into every worker), the document (`document.json` or the .fig, read and
// parsed), the first page's nodes, the images it shows, and its first frame. Each step
// reports how much of it is done (bytes where they are counted); the bar is the sum, so
// it only grows whatever order the steps run in. It goes once the first frame is up.
import { Publr } from "publr-jsx";

export type Step = "engine" | "document" | "page" | "images" | "frame";

const SHARE: Record<Step, number> = {
  engine: 0.3,
  document: 0.3,
  page: 0.25,
  images: 0.1,
  frame: 0.05,
};

/** How long the splash takes to fade out, ms. */
export const FADE_MS = 150;

export const loading = Publr.reactive({
  /** The splash covers the window (from the first render on a file's address, before
   * the opening starts). */
  shown: typeof location !== "undefined" && location.pathname.startsWith("/file/"),
  /** It is fading out. */
  leaving: false,
  /** 0 to 1. */
  progress: 0,
  /** Why the file did not open ("" while it opens). */
  error: "",
});

let active = false;
let done: Record<Step, number> = blank();
let fadeTimer = 0;

function blank(): Record<Step, number> {
  return { engine: 0, document: 0, page: 0, images: 0, frame: 0 };
}

/** A file starts opening: the splash shows, its bar empty. */
export function begin(): void {
  window.clearTimeout(fadeTimer);
  active = true;
  done = blank();
  loading.shown = true;
  loading.leaving = false;
  loading.progress = 0;
  loading.error = "";
}

/** The opening is under way (not finished, failed or closed). */
export function opening(): boolean {
  return active;
}

/** Step `step` is `fraction` done (0 to 1; never goes back). */
export function step(s: Step, fraction: number): void {
  if (!active) return;
  const f = Math.min(1, Math.max(0, fraction));
  if (f <= done[s]) return;
  done[s] = f;
  let sum = 0;
  for (const k of Object.keys(SHARE) as Step[]) sum += SHARE[k] * done[k];
  // Whole tenths of a percent: byte counts would otherwise redraw the bar per chunk.
  const p = Math.round(sum * 1000) / 1000;
  if (p > loading.progress) loading.progress = p;
}

/** Step `s` reported as bytes read of a total (unknown total: done when read). */
export function bytes(s: Step, read: number, total: number): void {
  step(s, total > 0 ? read / total : 0);
}

/** The first page is up: the bar fills and the splash fades out. */
export function finish(): void {
  if (!active) return;
  for (const k of Object.keys(SHARE) as Step[]) step(k, 1);
  active = false;
  loading.leaving = true;
  fadeTimer = window.setTimeout(() => {
    loading.shown = false;
    loading.leaving = false;
  }, FADE_MS);
}

/** The file did not open: the splash says why, with the way back to the files. */
export function fail(message: string): void {
  window.clearTimeout(fadeTimer);
  active = false;
  loading.shown = true;
  loading.leaving = false;
  // Engine and browser messages start lower-case and end bare: shown as a sentence.
  const text = message.trim() || "Something went wrong";
  loading.error = text[0].toUpperCase() + text.slice(1) + (/[.!?]$/.test(text) ? "" : ".");
}

/** The file closed (the browser shows): the splash goes at once. */
export function cancel(): void {
  window.clearTimeout(fadeTimer);
  active = false;
  loading.shown = false;
  loading.leaving = false;
  loading.error = "";
}
