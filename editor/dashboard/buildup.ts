// Build-up: our render stopped after N nodes, the Nth node framed and named. One step
// loads at a time; while it is in flight the newest wish waits and replaces older ones.
// Play advances about 20 nodes a second, skipping ahead when renders are slower.
import { currentItem, imageUrl, version } from "./data";
import { state } from "./store";
import type { Item, Step } from "./store";
import { setHighlight } from "./view";

let want = -1;
let loading = false;
let scrubTimer = 0;
let lastPlay = 0;

/** Starts build-up mode on an export: every node drawn, then that step loaded. */
export function enterBuild(it: Item): void {
  state.nodes = it.nodes;
  state.step = it.nodes;
  state.stepDrawn = "";
  state.stepNode = "";
  state.stepWhere = "";
  state.stepNote = "";
  setHighlight(null);
  want = -1;
  requestStep(it.nodes);
}

/** Moves to step `n`: at once, or after a short pause while the scrubber is dragged. */
export function setStep(n: number, now: boolean): void {
  const it = currentItem();
  if (!it) return;
  state.step = Math.max(0, Math.min(it.nodes, n));
  clearTimeout(scrubTimer);
  if (now) requestStep(state.step);
  else scrubTimer = window.setTimeout(() => requestStep(state.step), 90);
}

/** A step button or arrow key: stops playing and moves by `delta`. */
export function nudge(delta: number): void {
  stopPlay();
  setStep(state.step + delta, true);
}

export function scrub(event: Event): void {
  stopPlay();
  setStep(Number((event.target as HTMLInputElement).value), false);
}

function requestStep(n: number): void {
  want = n;
  if (loading) return;
  void loadStep();
}

async function loadStep(): Promise<void> {
  const it = currentItem();
  if (!it) return;
  const n = want;
  const file = it.file;
  const v = version();
  loading = true;
  state.busy = true;
  try {
    const src = imageUrl("ours", file, `&upto=${n}`);
    const image = new Image();
    image.src = src;
    await image.decode();
    const r = await fetch(`/api/step/${encodeURIComponent(file)}?upto=${n}&v=${v}`, { cache: "no-store" });
    const s = (await r.json()) as Step;
    if (state.mode === "build" && currentItem()?.file === file) {
      state.oursSrc = src;
      paintStep(s);
    }
  } catch {
    // A failed step leaves the last one shown.
  }
  loading = false;
  state.busy = false;
  if (want !== n && state.mode === "build") void loadStep();
  else if (state.playing) playNext();
}

function paintStep(s: Step): void {
  if (!s.node || s.drawn === 0) {
    setHighlight(null);
    state.stepDrawn = "";
    state.stepNode = "";
    state.stepWhere = "";
    state.stepNote = "nothing drawn";
    return;
  }
  setHighlight(s.bounds);
  state.stepNote = "";
  state.stepDrawn = `#${s.drawn}`;
  state.stepNode = `${s.node.type} "${s.node.name}"`;
  state.stepWhere = `${s.node.id}  [${s.bounds.join(", ")}]`;
}

function playNext(): void {
  const it = currentItem();
  if (!state.playing || !it) return;
  if (state.step >= it.nodes) {
    stopPlay();
    return;
  }
  const wait = Math.max(0, 50 - (performance.now() - lastPlay));
  window.setTimeout(() => {
    if (!state.playing) return;
    const now = performance.now();
    const advance = Math.max(1, Math.round(((now - lastPlay) * 20) / 1000));
    lastPlay = now;
    setStep(state.step + advance, true);
  }, wait);
}

export function startPlay(): void {
  const it = currentItem();
  if (state.mode !== "build" || !it) return;
  if (state.step >= it.nodes) setStep(0, true);
  state.playing = true;
  lastPlay = performance.now() - 50;
  if (!loading) playNext();
}

export function stopPlay(): void {
  state.playing = false;
}

export function togglePlay(): void {
  if (state.playing) stopPlay();
  else startPlay();
}
