// Starting engines and opening documents: the engine's module and the fonts into every
// worker once, then a document into all of them — a file of the browser (read from OPFS
// by each worker, page by page and asset by asset: feed.ts), the document `pe view`
// serves (read from it the same way), or bytes in hand.

import { sharedFontBytes } from "../home/fonts";
import { Engine, FontRole } from "./engine";
import { Feed, opfsFiles, readResponse, setFeed, urlFiles } from "./feed";
import type { Decoder, Helpers, NodeRun, OnBytes } from "./feed";
import type { DocInfo } from "./engine";
import { Pool } from "./pool";

/** The document `pe view` serves (`/api/doc`). */
export type ServerDoc = {
  kind: "pubd" | "fig";
  /** Its file name without the extension. */
  name: string;
  url: string;
  assets: string[];
};

/** Font URLs by role (`/api/fonts`). */
export type FontList = { faces: string[]; fallbacks: string[]; variable: string[] };

export type Asset = { hash: string; bytes: Uint8Array };

/** What to open: bytes in hand, a file of the browser by id, or a Pubd a server holds
 * (`base` + `document.json`, `pages/…`, `assets/…`). */
export type Source =
  | { kind: "pubd" | "fig"; name: string; bytes: Uint8Array; assets: Asset[] }
  | { kind: "file"; name: string; id: string }
  | { kind: "url"; name: string; base: string };

let wasmUrl = "";
let module: Promise<WebAssembly.Module> | null = null;
let fonts: Promise<FontList> | null = null;
let served: Promise<ServerDoc | null> | null = null;

/** Where the engine's WASM build is (set once, before anything starts). */
export function configure(url: string): void {
  wasmUrl = url;
}

export function engineModule(): Promise<WebAssembly.Module> {
  module ??= WebAssembly.compileStreaming(fetch(wasmUrl));
  return module;
}

function fontList(): Promise<FontList> {
  fonts ??= fetch("/api/fonts").then((r) => r.json() as Promise<FontList>);
  return fonts;
}

/** The document `pe view` serves, or null when it serves none. */
export function servedDoc(): Promise<ServerDoc | null> {
  served ??= fetch("/api/doc")
    .then((r) => (r.ok ? (r.json() as Promise<ServerDoc | null>) : null))
    .catch(() => null);
  return served;
}

export async function fetchBytes(url: string, onBytes?: OnBytes): Promise<Uint8Array> {
  const r = await fetch(url);
  if (!r.ok) throw new Error(`${url}: ${r.status}`);
  return readResponse(r, onBytes);
}

/** The fonts the server lists, fetched once (every engine takes the same bytes). */
let serverFonts: Promise<{ role: number; bytes: Uint8Array }[]> | null = null;
let fontsFetched = 0;

function fetchServerFonts(onFetched?: (done: number, total: number) => void): Promise<{ role: number; bytes: Uint8Array }[]> {
  serverFonts ??= fontList().then((list) => {
    const all: { role: number; url: string }[] = [];
    for (const url of list.faces) all.push({ role: FontRole.face, url });
    for (const url of list.fallbacks) all.push({ role: FontRole.fallback, url });
    for (const url of list.variable) all.push({ role: FontRole.variable, url });
    return Promise.all(
      all.map((f) =>
        fetchBytes(f.url).then((bytes) => {
          fontWaiters.forEach((w) => w(++fontsFetched, all.length));
          return { role: f.role, bytes };
        }),
      ),
    );
  });
  serverFonts.catch(() => (serverFonts = null));
  if (onFetched) fontWaiters.add(onFetched);
  return serverFonts.finally(() => onFetched && fontWaiters.delete(onFetched));
}
const fontWaiters = new Set<(done: number, total: number) => void>();

/** What opening a file needs, started as the page loads, before the app is up: the
 * engine's module compiled, the fonts fetched, the render workers started (`workers`
 * render workers; 0: none) and the engine on this thread made. Each is taken later by
 * what asks for it (`startWorkers`, `startMainEngine`). */
export function prestart(workers: number): void {
  void engineModule().catch(() => (module = null));
  void fetchServerFonts().catch(() => {});
  void servedDoc();
  if (workers > 0) {
    early = { count: workers, pool: startWorkers(workers, () => {}) };
    early.pool.catch(() => (early = null));
  }
  earlyEngine = startMainEngine();
  earlyEngine.catch(() => (earlyEngine = null));
}
let early: { count: number; pool: Promise<Pool> } | null = null;
let earlyEngine: Promise<Engine> | null = null;

/** The render workers `prestart` began, when there are `count` of them (taken once). */
export function takeEarlyWorkers(count: number): Promise<Pool> | null {
  const e = early;
  early = null;
  return e && e.count === count ? e.pool : null;
}

/** The engine on this thread `prestart` began (taken once). */
export function takeEarlyEngine(): Promise<Engine> | null {
  const e = earlyEngine;
  earlyEngine = null;
  return e;
}

/** Starts `count` workers running `script` (default: the render worker), each with the
 * engine and every font the server lists. `progress` hears what runs and how far the
 * whole has come (0 to 1). */
export async function startWorkers(count: number, progress: (text: string, fraction: number) => void, script?: URL): Promise<Pool> {
  // The workers start while the module compiles and the fonts come.
  const pool = new Pool(count, script);
  progress("Loading fonts…", 0.2);
  const [mod, server, shared] = await Promise.all([engineModule(), fetchServerFonts((done, total) => progress(`Loading ${total} fonts…`, 0.2 + (0.6 * done) / total)), sharedFontBytes().catch(() => [])]);
  progress(`Starting ${count === 1 ? "the engine" : `${count} engine workers`}…`, 0.8);
  // Shared fonts first: a face the person added wins over the server's of the same name.
  const fonts = [...shared.map((f) => ({ role: FontRole.face, bytes: f.bytes, family: f.family, style: f.style })), ...server];
  await pool.all(() => ({ type: "init", module: mod, fonts }));
  progress("", 1);
  return pool;
}

/** The served document: a .fig as bytes; a .pubd read from the server as it is shown. */
export async function fetchServerDoc(info: ServerDoc, onBytes?: OnBytes): Promise<Source> {
  if (info.kind === "fig") return { kind: "fig", name: info.name, bytes: await fetchBytes(info.url, onBytes), assets: [] };
  return { kind: "url", name: info.name, base: "/doc/" };
}

/** Opens a document in every worker; the first answers with its pages. */
export async function openInWorkers(pool: Pool, source: Source): Promise<{ doc: DocInfo; ms: number[] }> {
  for (const slot of pool.slots) slot.ready = false;
  const answers = await pool.all((slot) =>
    source.kind === "file"
      ? { type: "doc", file: source.id, pages: slot.index === 0 }
      : source.kind === "url"
        ? { type: "doc", base: source.base, pages: slot.index === 0 }
        : { type: "doc", kind: source.kind, bytes: source.bytes, assets: source.assets, pages: slot.index === 0 },
  );
  for (const slot of pool.slots) slot.ready = true;
  return { doc: answers[0].doc as DocInfo, ms: answers.map((a) => a.ms as number) };
}

/** An engine on this thread, with every font: the GPU canvas walks its scene here. */
export async function startMainEngine(): Promise<Engine> {
  const [mod, server, shared] = await Promise.all([engineModule(), fetchServerFonts(), sharedFontBytes().catch(() => [])]);
  const engine = await Engine.create(mod);
  for (const f of shared) engine.addFontNamed(FontRole.face, f.bytes, f.family, f.style);
  for (const f of server) engine.addFont(f.role, f.bytes);
  return engine;
}

/** Opens a document in the engine on this thread (`onBytes` hears how much of
 * `document.json` is read). */
export async function openInEngine(engine: Engine, source: Source, onBytes?: OnBytes): Promise<void> {
  engine.gpuForget();
  setFeed(engine, null);
  if (source.kind === "file" || source.kind === "url") {
    // Read as it is shown: the canvas asks the feed before each frame.
    // This engine keeps the pages it has shown (under the budget of what is kept).
    const feed = new Feed(engine, source.kind === "file" ? opfsFiles(source.id) : urlFiles(source.base), true);
    try {
      await feed.open(onBytes);
    } catch (err) {
      feed.dispose();
      throw err;
    }
    setFeed(engine, feed);
  } else if (source.kind === "fig") {
    engine.loadFig(source.bytes);
  } else {
    engine.loadPubd(source.bytes);
    for (const asset of source.assets) engine.addAsset(asset.hash, asset.bytes);
  }
}

/** Drops the document from every worker. */
export async function closeInWorkers(pool: Pool): Promise<void> {
  for (const slot of pool.slots) slot.ready = false;
  await pool.all(() => ({ type: "close" }));
}

/** Images decoded by the render workers for the engine on this thread: up to sixteen
 * asked of each worker at a time (each holds the file's bytes while it waits), in the
 * order asked. Asked well ahead: the next is sent when one comes back, and while this
 * thread is busy (a big page's first frame) nothing comes back, so the workers keep busy
 * only on what they were asked before. */
export function workerDecoder(pool: Pool): Decoder {
  const queue: (() => void)[] = [];
  let running = 0;
  let next = 0;
  const limit = pool.slots.length * 16;
  const run = async (hash: string, level: number): Promise<Uint8Array | null> => {
    if (running >= limit) await new Promise<void>((go) => queue.push(go));
    running++;
    try {
      const slot = pool.slots[next++ % pool.slots.length];
      const r = await pool.call(slot, { type: "decode", hash, level });
      return (r.packed as Uint8Array | null) ?? null;
    } finally {
      running--;
      queue.shift()?.();
    }
  };
  return run;
}

/** Workers that only read a page's top-level nodes, besides the render workers: a big
 * page is read in all of them at once. Started when a page file is read, and let go a
 * while after the last read (the memory they read into goes with them). */
const READERS_IDLE_MS = 15000;
let readerPool: Promise<Pool> | null = null;
let readersIdle = 0;

function readers(count: number): Promise<Pool> | null {
  if (count <= 0) return null;
  window.clearTimeout(readersIdle);
  readerPool ??= engineModule().then(async (mod) => {
    const p = new Pool(count);
    await p.all(() => ({ type: "init", module: mod, fonts: [] }));
    return p;
  });
  return readerPool;
}

function idleReaders(): void {
  window.clearTimeout(readersIdle);
  readersIdle = window.setTimeout(() => {
    const p = readerPool;
    readerPool = null;
    void p?.then((pool) => pool.terminate());
  }, READERS_IDLE_MS);
}

/** What the render workers do for the engine on this thread: images decoded, page files
 * read with their top-level nodes found, and runs of those nodes read (in the render
 * workers and the readers at once: this thread only takes the nodes in). */
export function workerHelpers(pool: Pool): Helpers {
  let next = 0;
  let nextRun = 0;
  const cores = (typeof navigator !== "undefined" && navigator.hardwareConcurrency) || 4;
  // The cores the render workers and this thread leave, at most eight.
  const extra = Math.max(0, Math.min(8, cores - 1 - pool.slots.length));
  return {
    decode: workerDecoder(pool),
    page: async (src, parts) => {
      // The readers start while the file is read.
      if (parts) void readers(extra)?.catch(() => (readerPool = null));
      const slot = pool.slots[next++ % pool.slots.length];
      const r = await pool.call(slot, { type: "pagefile", src, parts });
      if (r.parts) return { head: r.head as Uint8Array, count: r.count as number, parts: r.parts as NodeRun[] };
      const bytes = r.bytes as Uint8Array | null;
      return bytes ? { bytes, spans: r.spans as number[] } : null;
    },
    // Runs of a page's nodes go to the readers and the render workers in turn (each reads
    // its runs in order).
    nodes: async (run) => {
      const rp = readerPool ? await readerPool.catch(() => null) : null;
      const slots = rp ? [...rp.slots, ...pool.slots] : pool.slots;
      const slot = slots[nextRun++ % slots.length];
      const owner = rp && rp.slots.includes(slot) ? rp : pool;
      try {
        const r = await owner.call(slot, { type: "nodes", bytes: run.bytes, spans: run.spans, head: run.head }, [run.bytes.buffer, run.head.buffer]);
        const all = r.blobs as Uint8Array;
        const ends = r.ends as number[];
        return ends.map((end, i) => all.subarray(i ? ends[i - 1] : 0, end));
      } finally {
        if (rp) idleReaders();
      }
    },
    readers: pool.slots.length + extra,
  };
}
