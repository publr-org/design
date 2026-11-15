// The files PublrDesign makes in the browser, kept in the origin private file system
// (OPFS). Memory only ever caches what is here; nothing goes to a server.
//
//   files/<id>/meta.json           FileMeta: name, times, project, trash
//   files/<id>/document.json       the Pubd document (for one kept page by page, the
//                                  pages' list, styles, assets and shared nodes)
//   files/<id>/pages/<id>.json     its pages, each read when it is shown
//   files/<id>/assets/<sha256>     its assets, named by the SHA-256 of their bytes, read
//                                  when a tile draws them
//   files/<id>/thumbnail.png       the card's picture (none for an empty file)
//   projects.json                  Project[]
//   served/meta.json               ServedMeta: the document `pe view` serves, as last seen
//   served/thumbnail.png           its card's picture
//   files/<id>/ with `served` in meta.json: the edits to that served document, kept here
//                                  (document.json and the pages edited); the pages and
//                                  assets not written here are read from the server
//
// meta.json is written last: a folder without one is an import that did not finish, and
// the listing skips it (and clears it out).
//
// Used by the page and by the import worker alike, so nothing here touches the DOM.

/** A file of the browser: what its card and the viewer's title show. */
export type FileMeta = {
  id: string;
  name: string;
  /** Milliseconds since the epoch. */
  created: number;
  edited: number;
  /** Last opened in the viewer; 0 when never. */
  opened: number;
  /** The project it is in; null: Drafts. */
  project: string | null;
  /** When it went to Trash; null while it is not there. */
  trashed: number | null;
  /** Where it came from. */
  source: "fig" | "pubd" | "new";
  pages: number;
  /** Has thumbnail.png. */
  thumbnail: boolean;
  /** Edits to the document `pe view` serves under this name: the folder holds only what
   * was written here (document.json, the pages edited); the rest is read from `origin`. */
  served?: string;
  /** Where the files this folder lacks are read from (the server's document, `/doc/`). */
  origin?: string;
};

export type Project = { id: string; name: string; created: number };

/** What the page remembers of the document `pe view` serves. */
export type ServedMeta = { name: string; opened: number; thumbnail: boolean };

/** The id the served document goes by in routes (`/file/served`). */
export const SERVED_ID = "served";

const encoder = new TextEncoder();
const decoder = new TextDecoder();

let rootHandle: Promise<FileSystemDirectoryHandle> | null = null;

export function root(): Promise<FileSystemDirectoryHandle> {
  rootHandle ??= navigator.storage.getDirectory();
  return rootHandle;
}

/** A fresh file or project id: 16 hex digits. */
export function newId(): string {
  const b = crypto.getRandomValues(new Uint8Array(8));
  return Array.from(b, (x) => x.toString(16).padStart(2, "0")).join("");
}

/** A lowercase hex SHA-256: the only names in `assets/`. */
export const isHash = (name: string) => /^[0-9a-f]{64}$/.test(name);

/** An id as the routes and folders take it (no way out of `files/`). */
export const isId = (id: string) => /^[0-9a-f]{16}$/.test(id);

async function dirOf(path: string[], create: boolean): Promise<FileSystemDirectoryHandle | null> {
  let d = await root();
  for (const name of path) {
    try {
      d = await d.getDirectoryHandle(name, { create });
    } catch {
      return null;
    }
  }
  return d;
}

/** The folder of file `id` (made when `create`). */
export function fileDir(id: string, create = false): Promise<FileSystemDirectoryHandle | null> {
  return dirOf(["files", id], create);
}

export async function writeBytes(dir: FileSystemDirectoryHandle, name: string, data: Uint8Array | Blob): Promise<void> {
  const h = await dir.getFileHandle(name, { create: true });
  const w = await h.createWritable();
  await w.write(data as FileSystemWriteChunkType);
  await w.close();
}

/** A document's JSON as the browser keeps it: gzip-compressed (pubd/SPEC.md). */
export async function pack(data: Uint8Array): Promise<Uint8Array> {
  const out = new Response(data).body!.pipeThrough(new CompressionStream("gzip"));
  return new Uint8Array(await new Response(out).arrayBuffer());
}

/** A document's file as stored, uncompressed (gzip is known by its first two bytes). */
export async function unpack(bytes: Uint8Array): Promise<Uint8Array> {
  if (bytes.length < 2 || bytes[0] !== 0x1f || bytes[1] !== 0x8b) return bytes;
  const out = new Response(bytes).body!.pipeThrough(new DecompressionStream("gzip"));
  return new Uint8Array(await new Response(out).arrayBuffer());
}

/** A document's file written into its folder: its JSON compressed, an asset as it is. */
export async function writeDocFile(dir: FileSystemDirectoryHandle, name: string, data: Uint8Array): Promise<void> {
  await writeBytes(dir, name, name.endsWith(".json") ? await pack(data) : data);
}

export async function readFile(dir: FileSystemDirectoryHandle, name: string): Promise<File | null> {
  try {
    return await (await dir.getFileHandle(name)).getFile();
  } catch {
    return null;
  }
}

export async function readBytes(dir: FileSystemDirectoryHandle, name: string): Promise<Uint8Array | null> {
  const f = await readFile(dir, name);
  return f ? new Uint8Array(await f.arrayBuffer()) : null;
}

export async function readJson<T>(dir: FileSystemDirectoryHandle, name: string): Promise<T | null> {
  const b = await readBytes(dir, name);
  if (!b) return null;
  try {
    return JSON.parse(decoder.decode(b)) as T;
  } catch {
    return null;
  }
}

export function writeJson(dir: FileSystemDirectoryHandle, name: string, value: unknown): Promise<void> {
  return writeBytes(dir, name, encoder.encode(JSON.stringify(value)));
}

// ------------------------------------------------------------------ files

/** Every finished file, newest edit first. Folders left by an unfinished import go. */
export async function listFiles(): Promise<FileMeta[]> {
  const files = await dirOf(["files"], true);
  if (!files) return [];
  const out: FileMeta[] = [];
  const unfinished: string[] = [];
  for await (const [name, h] of files.entries()) {
    if (h.kind !== "directory") continue;
    const meta = await readJson<FileMeta>(h as FileSystemDirectoryHandle, "meta.json");
    // The served document's edits show as that document, not as a file of their own.
    if (meta?.served) continue;
    if (meta) out.push(meta);
    else unfinished.push(name);
  }
  for (const name of unfinished) await files.removeEntry(name, { recursive: true }).catch(() => {});
  return out.sort((a, b) => b.edited - a.edited);
}

export async function getMeta(id: string): Promise<FileMeta | null> {
  if (!isId(id)) return null;
  const d = await fileDir(id);
  return d ? readJson<FileMeta>(d, "meta.json") : null;
}

export async function saveMeta(meta: FileMeta): Promise<void> {
  const d = await fileDir(meta.id, true);
  if (d) await writeJson(d, "meta.json", meta);
}

/** Changes some of a file's meta and saves it; the new meta, or null when gone. */
export async function updateMeta(id: string, change: Partial<FileMeta>): Promise<FileMeta | null> {
  const meta = await getMeta(id);
  if (!meta) return null;
  const next = { ...meta, ...change, id };
  await saveMeta(next);
  return next;
}

/** A new file's meta, before anything is written. */
export function freshMeta(id: string, name: string, source: FileMeta["source"], project: string | null): FileMeta {
  const now = Date.now();
  return { id, name, created: now, edited: now, opened: 0, project, trashed: null, source, pages: 1, thumbnail: false };
}

/** A new, empty design file: one page, "Page 1". */
export async function createEmpty(project: string | null): Promise<FileMeta> {
  const id = newId();
  const d = await fileDir(id, true);
  if (!d) throw new Error("cannot write the file");
  const doc = { pubd: 0, name: "Untitled", pages: [{ id: "0:1", type: "page", name: "Page 1", background: "#f5f5f5" }] };
  await writeJson(d, "document.json", doc);
  const meta = freshMeta(id, "Untitled", "new", project);
  await saveMeta(meta);
  return meta;
}

/** A copy of file `id`, named "<name> (Copy)", in the same place. */
export async function duplicate(id: string): Promise<FileMeta | null> {
  const meta = await getMeta(id);
  const from = await fileDir(id);
  if (!meta || !from) return null;
  const copyId = newId();
  const to = await fileDir(copyId, true);
  if (!to) return null;
  for (const name of ["document.json", "thumbnail.png"]) {
    const f = await readFile(from, name);
    if (f) await writeBytes(to, name, f);
  }
  for (const sub of ["assets", "pages"]) {
    const fromDir = await from.getDirectoryHandle(sub).catch(() => null);
    if (!fromDir) continue;
    const toDir = await to.getDirectoryHandle(sub, { create: true });
    for await (const [name, h] of fromDir.entries()) {
      if (h.kind === "file") await writeBytes(toDir, name, await (h as FileSystemFileHandle).getFile());
    }
  }
  const now = Date.now();
  const copy: FileMeta = { ...meta, id: copyId, name: `${meta.name} (Copy)`, created: now, edited: now, opened: 0, trashed: null };
  await saveMeta(copy);
  return copy;
}

/** Deletes file `id` for good. */
export async function removeFile(id: string): Promise<void> {
  if (!isId(id)) return;
  const files = await dirOf(["files"], true);
  await files?.removeEntry(id, { recursive: true }).catch(() => {});
}

/** A file of file `id` by its path in the folder (`document.json`, `pages/<id>.json`,
 * `assets/<sha256>`); null when it is not there. */
export async function readPath(id: string, path: string): Promise<Uint8Array | null> {
  const parts = path.split("/");
  if (!isId(id) || parts.some((p) => !p || p === "." || p === "..")) return null;
  const d = await dirOf(["files", id, ...parts.slice(0, -1)], false);
  const here = d ? await readBytes(d, parts[parts.length - 1]) : null;
  if (here) return unpack(here);
  // A folder of edits to another document: what it lacks is read from there.
  const origin = await originOf(id);
  if (!origin) return null;
  const r = await fetch(origin + path).catch(() => null);
  return r?.ok ? unpack(new Uint8Array(await r.arrayBuffer())) : null;
}

const origins = new Map<string, Promise<string>>();

/** Where file `id` reads what it lacks ("": nowhere). */
function originOf(id: string): Promise<string> {
  let o = origins.get(id);
  if (!o) {
    o = getMeta(id).then((m) => m?.origin ?? "");
    origins.set(id, o);
  }
  return o;
}

/** The file keeping the edits to the document `pe view` serves as `name` (null: none
 * yet). */
export async function servedEdits(name: string): Promise<FileMeta | null> {
  const files = await dirOf(["files"], true);
  if (!files) return null;
  for await (const [, h] of files.entries()) {
    if (h.kind !== "directory") continue;
    const meta = await readJson<FileMeta>(h as FileSystemDirectoryHandle, "meta.json");
    if (meta?.served === name && !meta.trashed) return meta;
  }
  return null;
}

/** A file for the edits to the served document `name` (read from `origin` where it has
 * nothing of its own): its meta first, so the listing never takes it for an unfinished
 * import. */
export async function createServedEdits(name: string, origin: string): Promise<FileMeta> {
  const id = newId();
  const meta: FileMeta = { ...freshMeta(id, name, "pubd", null), served: name, origin };
  await saveMeta(meta);
  origins.set(id, Promise.resolve(origin));
  return meta;
}

/** Writes a file of file `id` by its path in the folder (`document.json`,
 * `pages/<id>.json`), making the folders on the way. */
export async function writePath(id: string, path: string, data: Uint8Array): Promise<void> {
  const parts = path.split("/");
  if (!isId(id) || parts.some((p) => !p || p === "." || p === "..")) throw new Error(`cannot write ${path}`);
  const d = await dirOf(["files", id, ...parts.slice(0, -1)], true);
  if (!d) throw new Error(`cannot write ${path}`);
  await writeDocFile(d, parts[parts.length - 1], data);
}

export async function thumbnailFile(id: string): Promise<File | null> {
  const d = id === SERVED_ID ? await dirOf(["served"], false) : await fileDir(id);
  return d ? readFile(d, "thumbnail.png") : null;
}

// ------------------------------------------------------------------ projects

export async function listProjects(): Promise<Project[]> {
  const r = await root();
  return (await readJson<Project[]>(r, "projects.json")) ?? [];
}

async function saveProjects(list: Project[]): Promise<void> {
  await writeJson(await root(), "projects.json", list);
}

export async function createProject(name: string): Promise<Project> {
  const p: Project = { id: newId(), name, created: Date.now() };
  await saveProjects([...(await listProjects()), p]);
  return p;
}

// ------------------------------------------------------------------ the served document

export async function servedMeta(name: string): Promise<ServedMeta> {
  const d = await dirOf(["served"], true);
  const meta = d ? await readJson<ServedMeta>(d, "meta.json") : null;
  // Another document served under this origin: what was kept of the last one goes.
  if (!meta || meta.name !== name) return { name, opened: 0, thumbnail: false };
  return meta;
}

export async function saveServed(meta: ServedMeta, thumbnail?: Uint8Array): Promise<void> {
  const d = await dirOf(["served"], true);
  if (!d) return;
  if (thumbnail) await writeBytes(d, "thumbnail.png", thumbnail);
  await writeJson(d, "meta.json", meta);
}
