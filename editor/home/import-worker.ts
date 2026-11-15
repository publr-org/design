// The import worker: turns a dropped or picked `.fig` or `.pubd` into a file of the
// browser, in OPFS, with the engine in WASM doing the reading.
//
//   .fig    imported in pieces, as `pe import-fig` does, so any size imports: the zip's
//           directory and canvas.fig are read from the File, then each image the file
//           names (hashed by the engine, written to assets/<sha256>, dropped), then each
//           page (built, written to pages/<id>.json, dropped), then document.json. The
//           whole file is never in memory, nor two images, nor two pages.
//   .pubd   the zip is read by the engine's zip reader: document.json kept as it is, its
//           pages/ and assets/<sha256> copied over
//
// Then the engine opens what was written (feed.ts) and draws the card picture from the
// first page, and meta.json goes in last.
//
// Messages in (each answered with the same `id`; progress goes out as `{ note }`):
//   { type: "init", module, fonts: [{ role, bytes }] }
//   { type: "import", fileId, name, project, file: File }   answers { meta }

import { Engine } from "../viewer/engine";
import type { ZipItem } from "../viewer/engine";
import { Feed, opfsFiles } from "../viewer/feed";
import { thumbnail } from "../viewer/thumbnail";
import { fileDir, freshMeta, isHash, removeFile, saveMeta, writeBytes, writeDocFile } from "./store";
import type { FileMeta } from "./store";

type Scope = {
  postMessage(message: unknown, transfer?: Transferable[]): void;
  onmessage: ((event: MessageEvent) => void) | null;
};

type Font = { role: number; bytes: Uint8Array; family?: string; style?: string };

const scope = self as unknown as Scope;
let engine: Engine | null = null;

const note = (text: string) => scope.postMessage({ note: text });

function live(): Engine {
  if (!engine) throw new Error("engine not started");
  return engine;
}

/** Whether the bytes are a zip holding a Pubd document (rather than a `.fig`). */
function isPubdZip(names: string[]): boolean {
  return names.some((n) => n === "document.json" || n.endsWith("/document.json"));
}

/** Bytes `from`..`to` of a File. */
async function slice(file: Blob, from: number, to: number): Promise<Uint8Array> {
  return new Uint8Array(await file.slice(from, to).arrayBuffer());
}

/** A zip entry's bytes, read from the File (inflated when deflated). */
async function entryBytes(file: Blob, it: ZipItem): Promise<Uint8Array> {
  const head = await slice(file, it.local, it.local + 30);
  const dv = new DataView(head.buffer, head.byteOffset, head.byteLength);
  if (head.length < 30 || dv.getUint32(0, true) !== 0x04034b50) throw new Error(`${it.name}: not a zip entry`);
  const start = it.local + 30 + dv.getUint16(26, true) + dv.getUint16(28, true);
  const raw = file.slice(start, start + it.csize);
  if (it.method === 0) return new Uint8Array(await raw.arrayBuffer());
  if (it.method !== 8) throw new Error(`${it.name}: zip method ${it.method}`);
  const out = raw.stream().pipeThrough(new DecompressionStream("deflate-raw"));
  return new Uint8Array(await new Response(out).arrayBuffer());
}

/** Writes a `.fig`'s import in pieces: assets, pages, then document.json. */
async function writeFig(e: Engine, dir: FileSystemDirectoryHandle, name: string, file: File): Promise<number> {
  note(`Reading ${name}…`);
  const tail = await slice(file, Math.max(0, file.size - 65535 - 22 - 76), file.size);
  const d = e.zipDirectory(tail, file.size);
  const items = e.zipList(await slice(file, d.offset, d.offset + d.size), d.count);
  const find = (n: string) => items.find((it) => it.name === n);
  const canvas = find("canvas.fig");
  if (!canvas) throw new Error(`${file.name} is not a .fig file we can open (no canvas.fig)`);
  const meta = find("meta.json");
  note(`Converting ${name}…`);
  const info = e.importOpen(await entryBytes(file, canvas), meta ? await entryBytes(file, meta) : null);

  const images = items.filter((it) => it.name.startsWith("images/") && e.importWants(it.name.slice(7)));
  if (images.length) {
    const assets = await dir.getDirectoryHandle("assets", { create: true });
    let n = 0;
    for (const it of images) {
      note(`Saving ${name}: image ${++n} of ${images.length}`);
      const bytes = await entryBytes(file, it);
      const hash = e.importImage(it.name.slice(7), bytes);
      await writeBytes(assets, hash, bytes);
    }
  }
  const pages = await dir.getDirectoryHandle("pages", { create: true });
  for (let i = 0; i < info.pages; i++) {
    note(`Converting ${name}: page ${i + 1} of ${info.pages}`);
    const pg = e.importPage(i);
    await writeDocFile(pages, pg.path.slice("pages/".length), pg.json);
  }
  await writeDocFile(dir, "document.json", e.importDocument());
  return info.pages;
}

/** Writes a `.pubd` zip's document.json as it is and its assets, then opens it. */
async function writePubd(e: Engine, dir: FileSystemDirectoryHandle, name: string, bytes: Uint8Array, names: string[]): Promise<void> {
  // The document may sit at the top or in one folder (a zipped `name.pubd/`).
  const docAt = names.reduce((best, n, i) => ((n === "document.json" || n.endsWith("/document.json")) && (best < 0 || n.length < names[best].length) ? i : best), -1);
  const prefix = names[docAt].slice(0, -"document.json".length);
  const json = e.zipRead(docAt);
  await writeDocFile(dir, "document.json", json);
  const assets: { hash: string; index: number }[] = [];
  const pageFiles: { file: string; index: number }[] = [];
  names.forEach((n, index) => {
    if (n.startsWith(`${prefix}assets/`) && isHash(n.slice(prefix.length + 7))) assets.push({ hash: n.slice(prefix.length + 7), index });
    const pf = n.slice(prefix.length + 6);
    if (n.startsWith(`${prefix}pages/`) && /^[\w.-]+\.json$/.test(pf)) pageFiles.push({ file: pf, index });
  });
  if (pageFiles.length) {
    const out = await dir.getDirectoryHandle("pages", { create: true });
    for (const p of pageFiles) await writeDocFile(out, p.file, e.zipRead(p.index));
  }
  if (assets.length) {
    const out = await dir.getDirectoryHandle("assets", { create: true });
    let n = 0;
    for (const a of assets) {
      note(`Saving ${name}: asset ${++n} of ${assets.length}`);
      await writeBytes(out, a.hash, e.zipRead(a.index));
    }
  }
  e.zipClose();
}

async function importFile(id: string, name: string, project: string | null, file: File): Promise<FileMeta> {
  const e = live();
  const dir = await fileDir(id, true);
  if (!dir) throw new Error("cannot write the file");
  try {
    let source: FileMeta["source"] = "fig";
    if (/\.(pubd|zip)$/i.test(file.name)) {
      note(`Reading ${name}…`);
      const bytes = new Uint8Array(await file.arrayBuffer());
      const names = e.zipOpen(bytes);
      if (!isPubdZip(names)) {
        e.zipClose();
        throw new Error(`${file.name} holds no document.json`);
      }
      source = "pubd";
      await writePubd(e, dir, name, bytes, names);
    } else {
      await writeFig(e, dir, name, file);
    }
    // Opened as the viewer opens it: document.json, then what the picture draws.
    note(`Drawing ${name}'s thumbnail…`);
    const feed = new Feed(e, opfsFiles(id));
    await feed.open();
    const pages = e.pages().pages.length;
    const png = await thumbnail(e, (...a) => feed.tile(...a));
    // The engine's memory never shrinks: this is the import's peak.
    note(`engine memory ${Math.round(e.stats().memory / 1048576)} MB`);
    if (png) await writeBytes(dir, "thumbnail.png", png);
    e.close();
    const meta: FileMeta = { ...freshMeta(id, name, source, project), pages, thumbnail: !!png };
    await saveMeta(meta);
    return meta;
  } catch (err) {
    e.close();
    await removeFile(id);
    throw err;
  }
}

async function handle(m: Record<string, unknown>): Promise<Record<string, unknown>> {
  switch (m.type) {
    case "init": {
      engine = await Engine.create(m.module as WebAssembly.Module);
      for (const font of m.fonts as Font[]) engine.addFontNamed(font.role, font.bytes, font.family, font.style);
      return {};
    }
    case "import":
      return { meta: await importFile(m.fileId as string, m.name as string, (m.project as string | null) ?? null, m.file as File) };
  }
  throw new Error(`unknown message ${String(m.type)}`);
}

scope.onmessage = async (event: MessageEvent) => {
  const m = event.data as Record<string, unknown>;
  try {
    scope.postMessage({ ...(await handle(m)), id: m.id, ok: true });
  } catch (err) {
    scope.postMessage({ id: m.id, ok: false, error: err instanceof Error ? err.message : String(err) });
  }
};
