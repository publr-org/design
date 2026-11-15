// Feeding an engine a document in pieces: `document.json` when the file opens, a page's
// file when the page is shown, an asset when something on screen draws it. What an
// engine holds follows the screen, not the file: one page's nodes, the images in view
// (decoded only as finely as they are drawn, the least recently drawn given back past a
// budget), never the whole file.
//
// A document in one file (older Pubd, or bytes in hand) has every page at once; its
// pages are simply always there.

import { readPath, unpack } from "../home/store";
import type { Engine } from "./engine";
import { keep } from "./keep";

/** Told of bytes read so far of a total (0: the total is not known). */
export type OnBytes = (read: number, total: number) => void;

/** Where a document's files come from: a file of the browser (OPFS) or a server. */
export type Files = { read(path: string, onBytes?: OnBytes): Promise<Uint8Array | null> };

export const opfsFiles = (id: string): Files => ({
  read: async (path, onBytes) => {
    const bytes = await readPath(id, path);
    if (bytes) onBytes?.(bytes.length, bytes.length);
    return bytes;
  },
});

export const urlFiles = (base: string): Files => ({
  read: async (path, onBytes) => {
    const r = await fetch(base + path);
    return r.ok ? unpack(await readResponse(r, onBytes)) : null;
  },
});

/** A response's body, read in chunks so `onBytes` can tell how far it has come. */
export async function readResponse(r: Response, onBytes?: OnBytes): Promise<Uint8Array> {
  if (!onBytes || !r.body) return new Uint8Array(await r.arrayBuffer());
  const total = Number(r.headers.get("content-length")) || 0;
  const reader = r.body.getReader();
  const chunks: Uint8Array[] = [];
  let read = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    chunks.push(value);
    read += value.length;
    onBytes(read, total);
  }
  if (chunks.length === 1) return chunks[0];
  const out = new Uint8Array(read);
  let at = 0;
  for (const c of chunks) {
    out.set(c, at);
    at += c.length;
  }
  return out;
}

/** Told of an asset whose bytes are not what its name (their SHA-256) says: a file an
 * earlier build imported wrongly. The asset is left out (it draws nothing). */
export const assetChecks = { onBroken: (_hash: string) => {} };

/** Whether `bytes` hash to `hash` (names that are not a SHA-256 are taken as they are). */
async function sameHash(bytes: Uint8Array, hash: string): Promise<boolean> {
  if (!/^[0-9a-f]{64}$/.test(hash)) return true;
  const d = new Uint8Array(await crypto.subtle.digest("SHA-256", bytes as BufferSource));
  let hex = "";
  for (const b of d) hex += b.toString(16).padStart(2, "0");
  return hex === hash;
}

/** Decoded images an engine keeps at most (bytes). */
export const IMAGE_BUDGET = 512 * 1048576;

/** Decodes image `hash` down to mip level `level` somewhere else (a render worker):
 * the packed chain `Engine.addMipmap` takes, or null when the asset is missing or
 * does not decode. */
export type Decoder = (hash: string, level: number) => Promise<Uint8Array | null>;

/** A run of a page file's top-level nodes: their JSON, where each is in it, and the
 * file less its top-level nodes (the copies its instances are written against). */
export type NodeRun = { bytes: Uint8Array; spans: number[]; head: Uint8Array };

/** A page file cut for reading in several places: the file less its top-level nodes,
 * how many there are, and runs of them in order. */
export type PageParts = { head: Uint8Array; count: number; parts: NodeRun[] };

/** A page file read elsewhere (a render worker) with where its top-level nodes are
 * (`Engine.childSpans`), cut in `parts` runs when asked; null when there is no such
 * file. */
export type PageReader = (src: string, parts?: number) => Promise<{ bytes: Uint8Array; spans: number[] } | PageParts | null>;

/** A run of top-level nodes read elsewhere: each node as the engine takes it
 * (`Engine.addPageChildBlob`). */
export type NodeReader = (run: NodeRun) => Promise<Uint8Array[]>;

/** Work done for an engine on another thread: images decoded, page files read (and
 * their nodes, in `readers` places at once). */
export type Helpers = { decode: Decoder; page: PageReader; nodes?: NodeReader; readers?: number };

/** How long one step of reading a page in pieces may run before the thread yields, ms. */
const PAGE_SLICE_MS = 8;

const nextTask = () => new Promise<void>((resolve) => setTimeout(resolve, 0));

/** A decoded image waiting to be handed to the engine. */
type Decoded = { hash: string; level: number; packed: Uint8Array | null };

/** Engine bytes a page takes per byte of its file (its nodes and its records, measured
 * on Untitled UI's pages): what room is made before a page is read. */
const PAGE_BYTES_PER_FILE_BYTE = 0.9;

let feedSerial = 0;

export class Feed {
  engine: Engine;
  files: Files;
  /** Called when something a frame lacked has arrived (draw again). */
  onReady: () => void = () => {};
  private assetsInFlight = new Map<string, Promise<void>>();
  /** Assets whose bytes are damaged: never asked for again. */
  private broken = new Set<string>();
  /** The document carries its texts' stored glyphs (a `.fig` import of this build). */
  storedText = false;
  private pagesInFlight = new Map<number, Promise<void>>();
  /** Pages read, the most recently shown last. */
  private loaded: number[] = [];
  /** When each page read was last shown (`Date.now()`), and the engine bytes it took. */
  private shownAt = new Map<number, number>();
  private pageLive = new Map<number, number>();
  /** Pages whose images in view were asked for before their first frame (`ready`). */
  private primed = new Set<number>();
  /** Keeps the pages read under the budget of everything kept (`keep.ts`); otherwise
   * only the page shown stays (a render worker). */
  readonly keepsPages: boolean;
  /** The page shown now (it never goes). */
  shown = -1;
  /** Told when a page read is given back (what was kept of it elsewhere goes too). */
  onUnload: (page: number) => void = () => {};
  /** GPU bytes kept for page `page` (the records'), for the budget. */
  gpuBytes: (page: number) => number = () => 0;
  private serial = feedSerial++;
  private unkeep: (() => void) | null = null;
  /** Told how far the first page's nodes and the images asked for have come (the
   * splash's bar; set while the file opens). */
  onProgress: ((what: "page" | "images", fraction: number) => void) | null = null;
  /** Told when a page's file has been read in (its nodes are in the engine now). */
  onRead: ((page: number) => void) | null = null;
  /** Images asked for since the document opened, and those in. */
  private imagesAsked = 0;
  private imagesIn = 0;

  /** Where images are decoded (null: the engine decodes them as it draws). */
  private decoder: Decoder | null = null;
  /** Where page files are read and split (null: here, whole), and their nodes read. */
  private pageReader: PageReader | null = null;
  private nodeReader: NodeReader | null = null;
  private readers = 1;
  /** Pages read in pieces go one at a time. */
  private pageQueue: Promise<void> = Promise.resolve();
  /** Images being decoded elsewhere, by hash: the level asked. */
  private decoding = new Map<string, number>();
  /** Decoded images not yet handed over (`install`). */
  private decoded: Decoded[] = [];

  constructor(engine: Engine, files: Files, keepsPages = false) {
    this.engine = engine;
    this.files = files;
    this.keepsPages = keepsPages;
    if (keepsPages) {
      keep.engine(engine);
      this.unkeep = keep.add(() =>
        this.loaded
          .filter((p) => p !== this.shown && !this.pagesInFlight.has(p))
          .map((p) => ({
            id: `page ${this.serial}/${p}`,
            used: this.shownAt.get(p) ?? 0,
            engine: this.engine,
            live: this.pageLive.get(p) ?? 0,
            gpu: this.gpuBytes(p),
            file: false,
            drop: () => this.giveBack(p),
          })),
      );
    }
  }

  /** The feed is no longer used (its document closed): its pages leave the budget. */
  dispose(): void {
    this.unkeep?.();
    this.unkeep = null;
    if (this.keepsPages) keep.forget(this.engine);
  }

  /** The pages read: each one's engine bytes and when it was last shown (checks). */
  kept(): { page: number; live: number; used: number }[] {
    return this.loaded.map((page) => ({ page, live: this.pageLive.get(page) ?? 0, used: this.shownAt.get(page) ?? 0 }));
  }

  /** Whether page `page`'s nodes are here. */
  isLoaded(page: number): boolean {
    const f = this.engine.pageFile(page);
    return !f.src || f.loaded;
  }

  /** Gives page `page`'s nodes back (and its records); false when it stays (unsaved
   * changes keep a page). */
  private giveBack(page: number): boolean {
    this.engine.unloadPage(page);
    // What the frame builder keeps refers to nodes that are gone.
    this.engine.sceneForget();
    this.primed.delete(page);
    if (!this.isLoaded(page)) {
      this.loaded = this.loaded.filter((p) => p !== page);
      this.shownAt.delete(page);
      this.pageLive.delete(page);
      this.onUnload(page);
      return true;
    }
    return false;
  }

  /** Room for a page of `fileBytes` (its file): the pages read longest ago go (a render
   * worker keeps only the page shown). */
  private makeRoom(fileBytes: number): void {
    if (!this.keepsPages) {
      for (const p of [...this.loaded]) this.giveBack(p);
      return;
    }
    keep.fit(this.engine, fileBytes * PAGE_BYTES_PER_FILE_BYTE);
  }

  /** Images are decoded and page files read by `helpers` from now on (off this
   * thread): the engine's renders note what they want and draw what they hold, and a
   * page is read in pieces, a few top-level nodes a step. */
  useHelpers(helpers: Helpers): void {
    this.decoder = helpers.decode;
    this.pageReader = helpers.page;
    this.nodeReader = helpers.nodes ?? null;
    this.readers = helpers.readers ?? 1;
    this.engine.decodeElsewhere(true);
  }

  /** Whether images come decoded from elsewhere. */
  get decodesElsewhere(): boolean {
    return this.decoder !== null;
  }

  /** Asks for what the last render wanted (`Engine.takeWanted`): each image once at the
   * finest level asked. */
  want(list: [string, number][]): void {
    const decode = this.decoder;
    if (!decode) return;
    for (const [hash, level] of list) {
      if (this.broken.has(hash)) continue;
      const asked = this.decoding.get(hash);
      if (asked !== undefined && asked <= level) continue;
      this.decoding.set(hash, level);
      if (asked === undefined) this.imagesAsked++;
      decode(hash, level)
        .catch((err) => {
          console.error("image", hash, err);
          return null;
        })
        .then((packed) => {
          // A finer level asked meanwhile: this one still serves until that comes.
          if (this.decoding.get(hash) === level) this.decoding.delete(hash);
          this.decoded.push({ hash, level, packed });
          this.onReady();
        });
    }
  }

  /** Hands decoded images to the engine for up to `budgetMs` (at least one); true
   * while some still wait (the canvas draws again next frame). */
  /** Decoded images handed over so far (pictures drawn without one draw again). */
  installed = 0;

  /** When each image was last handed over (the `installed` count then). */
  private installedAt = new Map<string, number>();

  /** Whether image `hash` was handed over after `count` images were (a picture drawn
   * then without it is drawn again). */
  installedSince(hash: string, count: number): boolean {
    return (this.installedAt.get(hash) ?? -1) >= count;
  }

  /** What the last render wanted, asked for; the hashes it lacked. */
  takeWanted(): string[] {
    if (!this.decoder) return [];
    const wanted = this.engine.takeWanted();
    this.want(wanted);
    return wanted.map((w) => w[0]);
  }

  install(budgetMs: number): boolean {
    const t0 = performance.now();
    while (this.decoded.length) {
      const d = this.decoded.shift()!;
      this.installedAt.set(d.hash, this.installed);
      this.installed++;
      if (d.packed) {
        try {
          this.engine.addMipmap(d.hash, d.packed);
        } catch (err) {
          console.error("image", d.hash, err);
        }
      } else if (!this.decoding.has(d.hash)) {
        this.broken.add(d.hash);
        this.engine.markBad(d.hash);
      }
      if (!this.decoding.has(d.hash)) {
        this.imagesIn++;
        this.onProgress?.("images", this.imagesIn / Math.max(1, this.imagesAsked));
      }
      if (performance.now() - t0 >= budgetMs) break;
    }
    return this.decoded.length > 0;
  }

  /** Images are being decoded or wait to be handed over. */
  busy(): boolean {
    return this.decoding.size > 0 || this.decoded.length > 0;
  }

  /** Every image asked for is in the engine (decoded ones handed over as they come). */
  private settle(): Promise<void> {
    return new Promise((resolve) => {
      const step = () => {
        this.install(Infinity);
        if (this.busy()) setTimeout(step, 10);
        else resolve();
      };
      step();
    });
  }

  /** In a worker: image `hash`'s file read, checked and decoded down to `level`, packed
   * for the engine that draws (null when missing or damaged). */
  async decodeAsset(hash: string, level: number): Promise<Uint8Array | null> {
    if (this.broken.has(hash)) return null;
    const bytes = await this.files.read(`assets/${hash}`);
    if (!bytes) return null;
    if (!(await sameHash(bytes, hash))) {
      this.broken.add(hash);
      assetChecks.onBroken(hash);
      return null;
    }
    try {
      return this.engine.decodeImage(bytes, level);
    } catch {
      this.broken.add(hash);
      return null;
    }
  }

  /** Opens the document: `document.json` only. */
  async open(onBytes?: OnBytes): Promise<void> {
    this.imagesAsked = 0;
    this.imagesIn = 0;
    const json = await this.files.read("document.json", onBytes);
    if (!json) throw new Error("the file has no document.json");
    this.engine.loadPubd(json);
    this.storedText = /"glyphs"\s*:/.test(new TextDecoder().decode(json));
    this.engine.lazyAssets(true, IMAGE_BUDGET);
    this.loaded = [];
    this.shownAt.clear();
    this.pageLive.clear();
    this.primed.clear();
  }

  /** Page `page`'s nodes, read when the page is in its own file; pages shown longest
   * ago are given back. */
  page(page: number): Promise<void> {
    const f = this.engine.pageFile(page);
    if (!f.src || f.loaded) {
      this.touch(page);
      return Promise.resolve();
    }
    let p = this.pagesInFlight.get(page);
    if (!p) {
      this.primed.delete(page);
      p = (this.pageReader ? this.pieced(page, f.src) : (async () => {
        const t0 = performance.now();
        const bytes = await this.files.read(f.src, (read, total) => this.onProgress?.("page", total ? (0.8 * read) / total : 0));
        if (!bytes) throw new Error(`the file has no ${f.src}`);
        const t1 = performance.now();
        this.makeRoom(bytes.length);
        const live0 = this.engine.live();
        this.engine.loadPage(page, bytes);
        this.pageLive.set(page, this.engine.live() - live0);
        const t2 = performance.now();
        console.info(`page ${page}: ${(bytes.length / 1048576).toFixed(1)} MB read in ${Math.round(t1 - t0)} ms, opened in ${Math.round(t2 - t1)} ms; engine ${Math.round(this.engine.stats().memory / 1048576)} MB`);
        this.onRead?.(page);
        this.touch(page);
        this.onProgress?.("page", 1);
      })()).finally(() => this.pagesInFlight.delete(page));
      this.pagesInFlight.set(page, p);
    }
    return p;
  }

  /** Page `page` read elsewhere and put in the engine a few top-level nodes a step, the
   * thread yielding between steps (the canvas and the panels keep their frames). */
  private pieced(page: number, src: string): Promise<void> {
    const run = this.pageQueue.then(async () => {
      const t0 = performance.now();
      this.onProgress?.("page", 0.1);
      // With node readers: the file comes cut in runs, each read in another worker
      // (several at once), and this thread only takes the nodes in.
      const nodes = this.nodeReader;
      const r = await this.pageReader!(src, nodes ? this.readers * 2 : undefined);
      if (!r) throw new Error(`the file has no ${src}`);
      const t1 = performance.now();
      this.makeRoom("parts" in r ? r.head.length + r.parts.reduce((a, x) => a + x.bytes.length, 0) : r.bytes.length);
      const live0 = this.engine.live();
      let longest = 0;
      if ("parts" in r) {
        const runs = r.parts.map((run) => nodes!(run));
        // Each is waited for in order; one failing fails the page (the rest are let go).
        for (const run of runs) run.catch(() => {});
        this.engine.beginPage(page, r.head, r.count);
        try {
          let slice = performance.now();
          let done = 0;
          for (const run of runs) {
            for (const blob of await run) {
              const c0 = performance.now();
              this.engine.addPageChildBlob(page, blob);
              const c1 = performance.now();
              longest = Math.max(longest, c1 - c0);
              this.onProgress?.("page", 0.2 + (0.8 * ++done) / r.count);
              if (c1 - slice >= PAGE_SLICE_MS) {
                await nextTask();
                slice = performance.now();
              }
            }
          }
          this.engine.endPage(page);
        } catch (err) {
          this.engine.cancelPage();
          throw err;
        }
        const t2 = performance.now();
        this.pageLive.set(page, this.engine.live() - live0);
        console.info(`page ${page}: ${r.count} nodes read in ${Math.round(t1 - t0)} ms, read in ${r.parts.length} runs and taken in by ${Math.round(t2 - t1)} ms (longest ${Math.round(longest)} ms); engine ${Math.round(this.engine.stats().memory / 1048576)} MB, the page ${Math.round((this.engine.live() - live0) / 1048576)} MB`);
        this.onRead?.(page);
        this.touch(page);
        this.onProgress?.("page", 1);
        return;
      }
      const { bytes, spans } = r;
      if (!spans.length) {
        this.engine.loadPage(page, bytes);
      } else {
        const head = new Uint8Array(spans[0] + 1 + bytes.length - (spans[1] - 1));
        head.set(bytes.subarray(0, spans[0] + 1), 0);
        head.set(bytes.subarray(spans[1] - 1), spans[0] + 1);
        const count = (spans.length - 2) / 2;
        this.engine.beginPage(page, head, count);
        let slice = performance.now();
        for (let k = 2; k < spans.length; k += 2) {
          const c0 = performance.now();
          this.engine.addPageChild(page, bytes.subarray(spans[k], spans[k + 1]));
          const c1 = performance.now();
          longest = Math.max(longest, c1 - c0);
          this.onProgress?.("page", 0.2 + (0.8 * (k / 2)) / count);
          if (c1 - slice >= PAGE_SLICE_MS && k + 2 < spans.length) {
            await nextTask();
            slice = performance.now();
          }
        }
        this.engine.endPage(page);
      }
      const t2 = performance.now();
      this.pageLive.set(page, this.engine.live() - live0);
      console.info(`page ${page}: ${(bytes.length / 1048576).toFixed(1)} MB read in ${Math.round(t1 - t0)} ms, opened in ${Math.round(t2 - t1)} ms in ${spans.length ? (spans.length - 2) / 2 : 1} steps (longest ${Math.round(longest)} ms); engine ${Math.round(this.engine.stats().memory / 1048576)} MB`);
      this.onRead?.(page);
      this.touch(page);
      this.onProgress?.("page", 1);
    });
    this.pageQueue = run.catch(() => {});
    return run;
  }

  private touch(page: number): void {
    this.loaded = this.loaded.filter((p) => p !== page);
    this.loaded.push(page);
    this.shownAt.set(page, Date.now());
  }

  /** Page `page` is the one shown now: it never goes, and it counts as shown last. */
  show(page: number): void {
    if (this.shown === page) return;
    if (this.shown >= 0 && this.loaded.includes(this.shown)) this.shownAt.set(this.shown, Date.now());
    this.shown = page;
    if (this.loaded.includes(page)) this.touch(page);
  }

  /** The records of page `page` took `bytes` more of the engine (they go with the page). */
  addLive(page: number, bytes: number): void {
    if (this.loaded.includes(page)) this.pageLive.set(page, (this.pageLive.get(page) ?? 0) + bytes);
  }

  /** Reads and hands over the assets named (each once, however often asked). */
  assets(hashes: string[]): Promise<void> {
    return Promise.all(
      this.usable(hashes).map((hash) => {
        let p = this.assetsInFlight.get(hash);
        if (!p) {
          this.imagesAsked++;
          p = this.files
            .read(`assets/${hash}`)
            .then(async (bytes) => {
              if (!bytes) return;
              if (!(await sameHash(bytes, hash))) {
                this.broken.add(hash);
                assetChecks.onBroken(hash);
                return;
              }
              this.engine.addAsset(hash, bytes);
            })
            .finally(() => {
              this.assetsInFlight.delete(hash);
              this.imagesIn++;
              this.onProgress?.("images", this.imagesIn / this.imagesAsked);
            });
          this.assetsInFlight.set(hash, p);
        }
        return p;
      }),
    ).then(() => {});
  }

  /** `hashes` less the damaged ones. */
  private usable(hashes: string[]): string[] {
    return this.broken.size ? hashes.filter((h) => !this.broken.has(h)) : hashes;
  }

  /** Everything a `renderTile` with these arguments draws, read. */
  async tile(page: number, x: number, y: number, scale: number, w: number, h: number): Promise<void> {
    await this.page(page);
    await this.assets(this.engine.missingTile(page, x, y, scale, w, h));
  }

  /** Everything a `renderNode(id, scale)` draws, read (on a page already shown). */
  async node(id: string, scale: number): Promise<void> {
    if (this.decoder) {
      this.engine.missingNode(id, scale);
      this.want(this.engine.takeWanted());
      await this.settle();
      return;
    }
    await this.assets(this.engine.missingNode(id, scale));
  }

  /** After a render with images decoded elsewhere: asks for what it wanted; true when
   * it had everything (nothing wanted, nothing on its way). */
  rendered(): boolean {
    if (!this.decoder) return true;
    const wanted = this.engine.takeWanted();
    this.want(wanted);
    return wanted.length === 0 && !this.busy();
  }

  /** For a frame drawn now: true when it has all it draws; otherwise starts reading
   * what it lacks and calls `onReady` when that is in. */
  ready(page: number, x: number, y: number, scale: number, w: number, h: number): boolean {
    const f = this.engine.pageFile(page);
    if (f.src && !f.loaded) {
      this.page(page)
        .then(() => this.onReady())
        .catch((err) => console.error("page", err));
      return false;
    }
    // Images decoded elsewhere: the frame itself says what it lacked (`rendered`). A
    // page's first frame asks for the images in view before it is built, so they decode
    // in the workers while it builds (a big page's first frame takes a second).
    if (this.decoder) {
      if (!this.primed.has(page)) {
        this.primed.add(page);
        this.engine.missingTile(page, x, y, scale, w, h);
        this.want(this.engine.takeWanted());
      }
      return true;
    }
    const need = this.usable(this.engine.missingTile(page, x, y, scale, w, h));
    if (!need.length) return true;
    this.assets(need)
      .then(() => this.onReady())
      .catch((err) => console.error("assets", err));
    return false;
  }
}

const feeds = new WeakMap<Engine, Feed>();

/** The feed an engine's document comes through (none for bytes in hand). */
export function feedOf(engine: Engine): Feed | undefined {
  return feeds.get(engine);
}

export function setFeed(engine: Engine, feed: Feed | null): void {
  const old = feeds.get(engine);
  if (old && old !== feed) old.dispose();
  if (feed) feeds.set(engine, feed);
  else feeds.delete(engine);
}
