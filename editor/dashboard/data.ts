// What the server knows and what is chosen: `/api/state` polled once a second (a new
// `started` means the server restarted with a rebuilt engine, so every score is stale),
// the scores fetched one at a time in the background with the selected export first,
// the sidebar's frames and the totals written into the store, and the selection and
// mode, remembered in localStorage.
import { enterBuild, stopPlay } from "./buildup";
import { MODES, state } from "./store";
import type { GroupView, Item, Mode, Num, RowView, Score, SectionView, ServerState, Tone } from "./store";
import { forgetPixels, relayout, startFlicker, stopFlicker } from "./view";

/** localStorage, which a private window or blocked site data may refuse. */
const prefs = {
  get(key: string): string | null {
    try {
      return localStorage.getItem(`pe.${key}`);
    } catch {
      return null;
    }
  },
  set(key: string, value: string): void {
    try {
      localStorage.setItem(`pe.${key}`, value);
    } catch {
      // Not remembered; the page works the same.
    }
  },
};

let server: ServerState | null = null;
let scores: Record<string, Score> = {};
let queue: string[] = [];
let scoring = false;
let current: Item | null = null;
/** Frames start collapsed; only their arrow opens them. */
const openTops = new Set<string>();
/** The frames in sidebar order (by name), each with its exports grouped by node. */
let frames: { top: string; name: string; items: Item[] }[] = [];

/** The server's start time: every image URL carries it, so a restart loads fresh. */
export const version = (): number => server?.started ?? 0;

export const items = (): Item[] => server?.items ?? [];

export const currentItem = (): Item | null => current;

export function imageUrl(kind: "ref" | "ours" | "diff", file: string, extra = ""): string {
  return `/${kind}/${encodeURIComponent(file)}.png?v=${version()}${extra}`;
}

const pct = (x: number): string => `${x.toFixed(2)}%`;

export function toneOf(visual: number | null): Tone {
  if (visual === null) return "none";
  return visual >= 99 ? "good" : visual >= 95 ? "warn" : "bad";
}

// ---- the sidebar and the numbers ----

function groupFrames(list: Item[]): void {
  const byTop = new Map<string, { top: string; name: string; items: Item[] }>();
  for (const it of list) {
    let frame = byTop.get(it.top);
    if (!frame) {
      frame = { top: it.top, name: it.top_name || it.top, items: [] };
      byTop.set(it.top, frame);
    }
    frame.items.push(it);
  }
  frames = [...byTop.values()].sort((a, b) => a.name.localeCompare(b.name, undefined, { numeric: true }));
}

function rowView(it: Item): RowView {
  const s = scores[it.file];
  return {
    file: it.file,
    scale: `${it.named_scale}x`,
    size: `${it.width}x${it.height}`,
    badge: s ? s.visual.toFixed(2) : "...",
    tone: toneOf(s ? s.visual : null),
    title: s ? `strict <=2 ${pct(s.within2)}, mean ${s.mean.toFixed(2)}, <=16 ${pct(s.within16)}, non-text ${pct(s.non_text_within2)}, ${s.ms} ms` : "",
    selected: current?.file === it.file,
  };
}

function sectionView(frame: { top: string; name: string; items: Item[] }): SectionView {
  // The frame's badge: the pixel-weighted visual score of everything scored inside it.
  let px = 0;
  let ok = 0;
  let n = 0;
  for (const it of frame.items) {
    const s = scores[it.file];
    if (!s) continue;
    n++;
    px += s.pixels;
    ok += s.visual * s.pixels;
  }
  const open = openTops.has(frame.top);
  const groups: GroupView[] = [];
  if (open) {
    for (const it of frame.items) {
      const last = groups[groups.length - 1];
      if (last && last.node === it.node) last.rows.push(rowView(it));
      else groups.push({ node: it.node, name: it.name || it.node, indent: Math.min(it.depth, 6) * 10, rows: [rowView(it)] });
    }
  }
  const all = frame.items.length;
  const visual = n ? ok / px : null;
  return {
    top: frame.top,
    name: frame.name,
    open,
    current: current?.top === frame.top,
    count: n < all ? `${n}/${all}` : `${all}`,
    badge: visual === null ? "..." : visual.toFixed(2),
    tone: toneOf(visual),
    groups,
  };
}

function paintTotal(): void {
  const list = items();
  let px = 0;
  let ok = 0;
  let n = 0;
  for (const it of list) {
    const s = scores[it.file];
    if (!s) continue;
    n++;
    px += s.pixels;
    ok += s.visual * s.pixels;
  }
  if (!n) {
    state.total = "-";
    state.totalTone = "none";
    state.totalNote = "scoring...";
    return;
  }
  const v = ok / px;
  const done = n === list.length;
  state.total = pct(v);
  state.totalTone = done ? toneOf(v) : "none";
  state.totalNote = done ? "of pixels within 2/255" : `${n} / ${list.length} scored`;
}

function paintNums(): void {
  const s = current ? scores[current.file] : undefined;
  state.title = current ? `${current.name}  ${current.node} @${current.named_scale}x` : "-";
  state.scored = !!s;
  const nums: Num[] = s
    ? [
        { label: "visual", value: pct(s.visual), unit: "" },
        { label: "≤2", value: pct(s.within2), unit: "" },
        { label: "≤16", value: pct(s.within16), unit: "" },
        { label: "non-text", value: pct(s.non_text_within2), unit: "" },
        { label: "mean", value: s.mean.toFixed(2), unit: "" },
        { label: "", value: String(s.ms), unit: "ms" },
      ]
    : [];
  state.nums = nums;
}

let refreshQueued = false;

/** Writes the sidebar, the total and the numbers into the store, once per frame. */
function refresh(): void {
  if (refreshQueued) return;
  refreshQueued = true;
  requestAnimationFrame(() => {
    refreshQueued = false;
    state.doc = server?.doc || "document";
    state.sections = frames.map(sectionView);
    paintTotal();
    paintNums();
  });
}

/** Opens or closes a frame; only its arrow does this. */
export function toggleFrame(top: string): void {
  if (openTops.has(top)) openTops.delete(top);
  else openTops.add(top);
  refresh();
}

/** A frame's name selects the frame's own render, at its smallest scale. */
export function selectFrame(top: string): void {
  const list = items();
  const own = list.filter((x) => x.node === top).sort((a, b) => a.named_scale - b.named_scale)[0] ?? list.find((x) => x.top === top);
  if (own) select(own.file);
}

// ---- scores ----

function queueScores(first: string | null): void {
  queue = items()
    .map((it) => it.file)
    .filter((f) => !scores[f]);
  if (first) {
    queue = queue.filter((f) => f !== first);
    queue.unshift(first);
  }
  void pumpScores();
}

async function pumpScores(): Promise<void> {
  if (scoring) return;
  scoring = true;
  const started = version();
  while (queue.length) {
    const f = queue.shift()!;
    if (scores[f]) continue;
    try {
      const r = await fetch(`/api/score/${encodeURIComponent(f)}?v=${started}`, { cache: "no-store" });
      if (!r.ok) {
        console.warn("score", f, r.status, await r.text());
        continue;
      }
      const s = (await r.json()) as Score;
      if (started !== version()) break;
      scores[f] = s;
      refresh();
    } catch {
      break;
    }
  }
  scoring = false;
  if (started !== version()) queueScores(current?.file ?? null);
}

// ---- selection and modes ----

/** Shows an export (the first when `file` is unknown) and puts it first in the queue. */
export function select(file: string | null): void {
  const list = items();
  const it = list.find((i) => i.file === file) ?? list[0];
  if (!it) return;
  const changed = !current || current.file !== it.file || current.width !== it.width || current.height !== it.height;
  current = it;
  prefs.set("file", it.file);
  state.file = it.file;
  state.width = it.width;
  state.height = it.height;
  layout(changed);
  refresh();
  requestAnimationFrame(() => requestAnimationFrame(() => document.querySelector('[data-file][aria-selected="true"]')?.scrollIntoView({ block: "nearest" })));
  if (!scores[it.file]) {
    queue = queue.filter((f) => f !== it.file);
    queue.unshift(it.file);
    void pumpScores();
  }
}

/** Moves the selection up or down the document's exports. */
export function selectNext(delta: number): void {
  const list = items();
  const i = list.findIndex((x) => x.file === current?.file) + delta;
  if (i >= 0 && i < list.length) select(list[i].file);
}

export function setMode(mode: Mode): void {
  state.mode = mode;
  prefs.set("mode", mode);
  layout(false);
}

/** Points the panes at the selected export in the current mode; a new size refits. */
function layout(refit: boolean): void {
  stopFlicker();
  stopPlay();
  const it = current;
  if (!it) return;
  state.shown++;
  state.refSrc = imageUrl("ref", it.file);
  state.diffSrc = imageUrl("diff", it.file);
  state.oursSrc = state.mode === "build" ? imageUrl("ours", it.file, `&upto=${it.nodes}`) : imageUrl("ours", it.file);
  if (state.mode === "flicker") startFlicker();
  if (state.mode === "build") enterBuild(it);
  relayout(refit);
}

// ---- live ----

let toastTimer = 0;

export function toast(text: string): void {
  state.toast = text;
  state.toastShown = true;
  clearTimeout(toastTimer);
  toastTimer = window.setTimeout(() => (state.toastShown = false), 1600);
}

/** Asks for the state every second; a new start time reloads everything. */
export async function poll(): Promise<void> {
  try {
    const r = await fetch("/api/state", { cache: "no-store" });
    const s = (await r.json()) as ServerState;
    state.live = true;
    if (!server || s.started !== server.started) {
      const first = !server;
      server = s;
      scores = {};
      forgetPixels();
      groupFrames(s.items);
      refresh();
      select(current ? current.file : prefs.get("file"));
      queueScores(current?.file ?? null);
      if (!first) toast("updated");
    }
  } catch {
    state.live = false;
  }
  window.setTimeout(() => void poll(), 1000);
}

/** The remembered mode, before the first layout. */
export function restoreMode(): void {
  const saved = prefs.get("mode");
  if (saved && MODES.some((m) => m.key === saved)) state.mode = saved as Mode;
}
