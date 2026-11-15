// What stays in memory on this thread once shown: the files open at once (a workspace's
// tabs, each in an engine of its own) and, in each, the pages read with their records on
// the GPU. Showing a page kept is a camera and a draw; a page not kept is read again
// behind the veil, and a file not kept opens from its file again.
//
// One budget covers both. The cost counted is what the engines' memories hold (WASM
// memory never shrinks, so an engine costs its size) and what the kept pages' records
// hold on the GPU. Before a page is read, and after, what was shown longest ago goes
// first until the cost fits: a page of the engine about to grow (giving it back lets the
// engine reuse its memory instead of growing), a page's records on the GPU, or a whole
// file (parked: saved and let go, its view kept). What is shown now never goes.

import type { Engine } from "./engine";

/** The budget for this device: a quarter of its memory, at most 2 GiB. Browsers that
 * tell it (Chrome's `navigator.deviceMemory`, in GB, rounded) get 512 MiB on a 2 GB
 * device and 1 GiB on 4 GB; the others, and 8 GB or more, get 2 GiB. */
function deviceBudget(): number {
  const gb = (navigator as Navigator & { deviceMemory?: number }).deviceMemory;
  const most = 2048 * 1048576;
  return gb ? Math.min(most, (gb * 1024 * 1048576) / 4) : most;
}

/** Something kept that can go: a page of a file, or a whole file. */
export type Keepable = {
  /** Names it among everything kept (the same on every ask). */
  id: string;
  /** When it was last shown (`Date.now()`). */
  used: number;
  /** The engine it lives in. */
  engine: Engine;
  /** A page: the engine bytes giving it back frees for the engine's reuse (a file: 0). */
  live: number;
  /** Bytes it holds on the GPU. */
  gpu: number;
  /** A whole file: its engine's memory goes with it. */
  file: boolean;
  /** Lets it go (false: it could not go, e.g. a page with unsaved changes). */
  drop: () => boolean;
};

/** What can be let go now (never what is shown). */
type Source = () => Keepable[];

const sources = new Set<Source>();
const named = new Map<string, Source>();
/** Every engine on this thread whose memory counts. */
const engines = new Set<Engine>();
/** What tells the bytes the GPU holds for what is kept (a canvas each). */
const gpuSources = new Set<() => number>();

export const keep = {
  /** Bytes the files open and their pages may hold on this thread, engines and GPU
   * records together (`window.pdTabs.budget` changes it for this visit). */
  budget: deviceBudget(),

  /** `source` tells what of its own can be let go (pages of a feed, files of the viewer);
   * one added under `name` replaces the one added under it before. */
  add(source: Source, name?: string): () => void {
    if (name) {
      const old = named.get(name);
      if (old) sources.delete(old);
      named.set(name, source);
    }
    sources.add(source);
    return () => sources.delete(source);
  },

  /** `engine`'s memory counts toward the budget (until `forget`). */
  engine(engine: Engine): void {
    engines.add(engine);
  },

  forget(engine: Engine): void {
    engines.delete(engine);
  },

  /** `fn` tells bytes the GPU holds for what is kept (a canvas's records). */
  gpu(fn: () => number): () => void {
    gpuSources.add(fn);
    return () => gpuSources.delete(fn);
  },

  /** Bytes held now: every engine's memory and the GPU's records. */
  held(): number {
    let n = 0;
    for (const fn of gpuSources) n += fn();
    for (const e of engines) n += e.memory.buffer.byteLength;
    return n;
  },

  /** Lets go of what was shown longest ago until what is held, plus `grow` bytes `engine`
   * is about to take (`gpu` more on the GPU), fits the budget. A page of `engine` frees
   * room inside it; another engine's page frees only its GPU share; a file frees its
   * engine. */
  fit(engine: Engine | null, grow = 0, gpu = 0): void {
    const tried = new Set<string>();
    for (let guard = 0; guard < 256; guard++) {
      const room = engine ? engine.memory.buffer.byteLength - engine.live() : 0;
      const need = Math.max(0, grow - room) + gpu;
      if (this.held() + need <= this.budget) return;
      const all = [...sources].flatMap((s) => s()).filter((k) => !tried.has(k.id));
      // Only what frees something toward this need: a page of another engine frees its
      // GPU share, a page of this one its share of the engine too.
      const useful = all.filter((k) => k.file || k.gpu > 0 || k.engine === engine);
      if (!useful.length) return;
      useful.sort((a, b) => a.used - b.used);
      const k = useful[0];
      tried.add(k.id);
      if (k.drop()) {
        const what = k.file ? "a file" : "a page";
        console.info(`keep: let go of ${what} shown ${Math.round((Date.now() - k.used) / 1000)} s ago (${Math.round((k.live + k.gpu) / 1048576)} MB); held ${Math.round(this.held() / 1048576)} MB of ${Math.round(this.budget / 1048576)} MB`);
      }
    }
  },
};

