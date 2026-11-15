// A render worker: one engine session holding the document, drawing one tile at a time.
//
// Messages in (each answered with the same `id`):
//   { type: "init", module, fonts: [{ role, bytes }] }
//   { type: "doc", kind: "pubd" | "fig", bytes, assets: [{ hash, bytes }], pages: bool }
//   { type: "doc", file: id, pages: bool }         a file of the browser, read from OPFS here
//   { type: "close" }                              drops the document (fonts stay)
//   { type: "thumbnail" }                          the card picture as PNG bytes (null: none)
//   { type: "tile", page, x, y, scale, size }     a tile as an ImageBitmap (null: empty)
//   { type: "node", node, scale, page? }           the node as `pe render` exports it (its page read first)
//   { type: "rect", page, x, y, scale, width, height }   raw pixels of any rect
//   { type: "hit", page, x, y }
//   { type: "layer", node, part, child, m, x0, y0, w, h }   part of a node for the GPU canvas
//                                                    (premultiplied RGBA8)
//   { type: "edit", changes: [{ page, edits, change }] }  replays what the editing engine
//                                                  did (held for a page not read here)
//   { type: "font", role, bytes }                  adds a font (a shared font added now)
//   { type: "fonts" }                              the fonts the document asks for
//   { type: "pagefile", src, parts? }              a page file read and its top-level nodes
//                                                  found, for the engine that reads it in pieces;
//                                                  with `parts`, cut there: the file less its
//                                                  top-level nodes (`head`) and runs of them
//   { type: "nodes", bytes, spans, head }          top-level nodes' JSON read here (their page's
//                                                  file less them: `head`), as bytes for the
//                                                  engine that draws (`blobs`)
//   { type: "decode", hash, level }               an image of the document decoded for the
//                                                  engine that draws (packed mip chain, or null)
//   { type: "stats" }

import { Engine } from "./engine";
import { assetChecks, Feed, opfsFiles, urlFiles } from "./feed";
import { thumbnail } from "./thumbnail";

type Scope = {
  postMessage(message: unknown, transfer?: Transferable[]): void;
  onmessage: ((event: MessageEvent) => void) | null;
};

type Font = { role: number; bytes: Uint8Array; family?: string; style?: string };
type Asset = { hash: string; bytes: Uint8Array };

const scope = self as unknown as Scope;
// A damaged asset is told to the page as a note (it shows the file needs importing again).
assetChecks.onBroken = (hash) => scope.postMessage({ note: `broken-asset ${hash}` });
let engine: Engine | null = null;
/** How the open document's pages and assets come in (null: all in hand). */
let feed: Feed | null = null;

/** Edits being replayed: everything that draws or reads the document waits for them, so
 * a message sent after an edit sees it. */
let editing: Promise<void> = Promise.resolve();

type Change = { page: number; edits: number; change: unknown };

/** Changes to pages not read here, by page file: applied when the page is read, those
 * its file does not hold yet (a page saved since holds some). */
const held = new Map<string, Change[]>();

/** Replays changes in order; a page not read here keeps its changes until it is. */
function replay(changes: Change[]): void {
  const e = live();
  let i = 0;
  while (i < changes.length) {
    const page = changes[i].page;
    let j = i;
    while (j < changes.length && changes[j].page === page) j++;
    const f = page >= 0 ? e.pageFile(page) : null;
    if (f && f.src && !f.loaded) {
      const list = held.get(f.src) ?? [];
      list.push(...changes.slice(i, j));
      held.set(f.src, list);
    } else e.editReplay(changes.slice(i, j));
    i = j;
  }
}

/** Page `page` was read: the changes held for it that its file lacks are applied. */
function pageRead(page: number): void {
  const e = live();
  const f = e.pageFile(page);
  const list = held.get(f.src);
  if (!list) return;
  held.delete(f.src);
  const missing = list.filter((c) => c.edits > f.edits);
  if (missing.length) e.editReplay(missing);
}

/** Reads what a tile draws, until the page it reads is still the one loaded after the
 * reads (another page may have been shown meanwhile). */
async function readyTile(page: number, x: number, y: number, scale: number, w: number, h: number): Promise<void> {
  if (!feed) return;
  for (let i = 0; i < 4; i++) {
    await feed.tile(page, x, y, scale, w, h);
    const f = live().pageFile(page);
    if (!f.src || f.loaded) return;
  }
}

function live(): Engine {
  if (!engine) throw new Error("engine not started");
  return engine;
}

/** Answers one message: the reply's fields and what to transfer with it. */
async function handle(m: Record<string, unknown>): Promise<[Record<string, unknown>, Transferable[]]> {
  if (m.type === "edit") {
    const run = editing.then(() => replay(m.changes as Change[]));
    editing = run.catch((err) => console.error("edit replay", err));
    await run;
    return [{}, []];
  }
  await editing;
  switch (m.type) {
    case "init": {
      engine = await Engine.create(m.module as WebAssembly.Module);
      let added = 0;
      for (const font of m.fonts as Font[]) if (engine.addFontNamed(font.role, font.bytes, font.family, font.style)) added++;
      return [{ fonts: added }, []];
    }
    case "doc": {
      const e = live();
      const t0 = performance.now();
      feed = null;
      held.clear();
      if (typeof m.file === "string" || typeof m.base === "string") {
        // document.json now; a page's file when it is shown; an asset when it is drawn.
        const f = new Feed(e, typeof m.file === "string" ? opfsFiles(m.file) : urlFiles(m.base as string));
        f.onRead = pageRead;
        await f.open();
        feed = f;
      } else if (m.kind === "fig") {
        e.loadFig(m.bytes as Uint8Array);
      } else {
        e.loadPubd(m.bytes as Uint8Array);
        for (const asset of m.assets as Asset[]) e.addAsset(asset.hash, asset.bytes);
      }
      const ms = performance.now() - t0;
      return [{ ms, doc: m.pages ? e.pages() : null }, []];
    }
    case "tile": {
      const e = live();
      const size = m.size as number;
      await readyTile(m.page as number, m.x as number, m.y as number, m.scale as number, size, size);
      const t0 = performance.now();
      const px = e.renderTile(m.page as number, m.x as number, m.y as number, m.scale as number, size, size, 0);
      const ms = performance.now() - t0;
      // Fully transparent tiles come back empty: nothing to draw, nothing to hold.
      let empty = true;
      for (let i = 3; i < px.length; i += 4) {
        if (px[i] !== 0) {
          empty = false;
          break;
        }
      }
      const bitmap = empty ? null : await createImageBitmap(new ImageData(px, size, size));
      const stats = e.stats();
      return [{ bitmap, ms, drawn: stats.drawn, culled: stats.culled, memory: stats.memory }, bitmap ? [bitmap] : []];
    }
    case "node": {
      if (typeof m.page === "number") await feed?.page(m.page);
      await feed?.node(m.node as string, m.scale as number);
      const r = live().renderNode(m.node as string, m.scale as number);
      return [{ width: r.width, height: r.height, data: r.data }, [r.data.buffer]];
    }
    case "rect": {
      const width = m.width as number;
      const height = m.height as number;
      await readyTile(m.page as number, m.x as number, m.y as number, m.scale as number, width, height);
      const data = live().renderTile(m.page as number, m.x as number, m.y as number, m.scale as number, width, height, 0);
      return [{ width, height, data }, [data.buffer]];
    }
    case "layer": {
      const mm = m.m as number[];
      if (typeof m.page === "number") await feed?.page(m.page);
      await feed?.node(m.node as string, Math.max(Math.hypot(mm[0], mm[1]), Math.hypot(mm[2], mm[3])));
      const t0 = performance.now();
      const data = live().renderLayer(m.node as string, m.part as number, m.child as number, m.m as number[], m.x0 as number, m.y0 as number, m.w as number, m.h as number);
      return [{ data, ms: performance.now() - t0 }, [data.buffer]];
    }
    case "hit":
      await feed?.page(m.page as number);
      return [{ hit: live().hitTest(m.page as number, m.x as number, m.y as number) }, []];
    case "close":
      feed = null;
      held.clear();
      live().close();
      return [{}, []];
    case "thumbnail": {
      const f = feed;
      const png = await thumbnail(live(), f ? (...a) => f.tile(...a) : undefined);
      return [{ png }, png ? [png.buffer] : []];
    }
    case "font":
      // A shared font added while the file is open.
      return [{ added: live().addFontNamed(m.role as number, m.bytes as Uint8Array, m.family as string | undefined, m.style as string | undefined) }, []];
    case "fonts":
      return [{ fonts: live().fonts() }, []];
    case "pagefile": {
      // A page file for the engine on the page's thread, with its top-level nodes found.
      const bytes = feed ? await feed.files.read(m.src as string) : null;
      if (!bytes) return [{ bytes: null, spans: [] }, []];
      const spans = live().childSpans(bytes);
      const parts = m.parts as number | undefined;
      if (!parts || spans.length < 4) return [{ bytes, spans }, [bytes.buffer]];
      // Cut for reading in several workers: the file less its top-level nodes, then runs
      // of them of about equal size, each its own buffer (handed on as it is).
      const head = new Uint8Array(spans[0] + 1 + bytes.length - (spans[1] - 1));
      head.set(bytes.subarray(0, spans[0] + 1), 0);
      head.set(bytes.subarray(spans[1] - 1), spans[0] + 1);
      const count = (spans.length - 2) / 2;
      const total = spans[spans.length - 1] - spans[2];
      const out: { bytes: Uint8Array; spans: number[] }[] = [];
      let k = 2;
      for (let i = 0; i < parts && k < spans.length; i++) {
        const from = spans[k];
        const until = spans[2] + (total * (i + 1)) / parts;
        const local: number[] = [];
        while (k < spans.length && (local.length === 0 || spans[k + 1] <= until || i === parts - 1)) {
          local.push(spans[k] - from, spans[k + 1] - from);
          k += 2;
        }
        out.push({ bytes: bytes.slice(from, from + local[local.length - 1]), spans: local, head: head.slice() });
      }
      return [{ head, count, parts: out }, [head.buffer, ...out.flatMap((p) => [p.bytes.buffer, p.head.buffer])]];
    }
    case "nodes": {
      // Top-level nodes read for the engine that draws: each one's bytes, end to end.
      const e = live();
      const bytes = m.bytes as Uint8Array;
      const spans = m.spans as number[];
      e.nodePage(m.head as Uint8Array);
      const blobs: Uint8Array[] = [];
      let size = 0;
      for (let k = 0; k < spans.length; k += 2) {
        const b = e.nodeBlob(bytes.subarray(spans[k], spans[k + 1]));
        blobs.push(b);
        size += b.length;
      }
      const all = new Uint8Array(size);
      const ends: number[] = [];
      let at = 0;
      for (const b of blobs) {
        all.set(b, at);
        at += b.length;
        ends.push(at);
      }
      return [{ blobs: all, ends }, [all.buffer]];
    }
    case "decode": {
      const packed = feed ? await feed.decodeAsset(m.hash as string, m.level as number) : null;
      return [{ packed }, packed ? [packed.buffer] : []];
    }
    case "stats":
      return [{ ...live().stats() }, []];
  }
  throw new Error(`unknown message ${String(m.type)}`);
}

scope.onmessage = async (event: MessageEvent) => {
  const m = event.data as Record<string, unknown>;
  try {
    const [out, transfer] = await handle(m);
    scope.postMessage({ ...out, id: m.id, ok: true }, transfer);
  } catch (err) {
    scope.postMessage({ id: m.id, ok: false, error: err instanceof Error ? err.message : String(err) });
  }
};
