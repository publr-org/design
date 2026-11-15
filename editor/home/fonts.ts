// Shared fonts: font files the person adds, kept in the browser and used by every file,
// as Figma's shared fonts are. They come from an upload or a drop (Fonts in the file
// browser), from this computer's installed fonts (Local Font Access, asked for from a
// click), or from Google Fonts' own repository for a family a file asks for.
//
//   fonts/<sha256>.<ext>   the file as it came (TTF, OTF, TTC, OTC, WOFF, WOFF2)
//   fonts/index.json       SharedFont[]: what each file holds, as the engine read it
//
// Every engine (render workers, the canvas engine, the import worker) takes them as
// faces when it starts; one added while a file is open reaches its engines at once
// (`fontsChannel`).

import { Engine } from "../viewer/engine";
import type { FontInfo } from "../viewer/engine";
import { engineModule } from "../viewer/loader";
import { readBytes, readJson, root, writeBytes, writeJson } from "./store";

export type SharedFont = {
  /** SHA-256 of the file, lowercase hex: its name in `fonts/`. */
  id: string;
  ext: string;
  /** The file's name as it came. */
  name: string;
  source: "upload" | "local" | "google";
  /** Milliseconds since the epoch. */
  added: number;
  bytes: number;
  faces: FontInfo["faces"];
  axes: FontInfo["axes"];
  /** The names it goes by when its own are missing or hidden (some web builds name
   * themselves "" and "¶"): read from the file's name. */
  family?: string;
  style?: string;
};

/** A font file's own name read as a family and style: "SuisseWorks-Bold-WebS.woff2" is
 * Suisse Works, Bold. */
export function nameFromFile(file: string): { family: string; style: string } {
  let base = file.replace(/\.[^.]+$/, "");
  while (/[-_ ](web|webs|webfont|subset|v\d+)$/i.test(base)) base = base.replace(/[-_ ](web|webs|webfont|subset|v\d+)$/i, "");
  const cut = base.search(/[-_]/);
  const spaced = (s: string) => s.replace(/([a-z])([A-Z])/g, "$1 $2").replace(/[_]+/g, " ").trim();
  const family = spaced(cut < 0 ? base : base.slice(0, cut));
  const style = cut < 0 ? "Regular" : spaced(base.slice(cut + 1)) || "Regular";
  return { family, style };
}

/** True when a face names itself readably. */
const named = (family: string) => /\p{L}{2}/u.test(family);

/** The files the font list takes. */
export const FONT_FILES = /\.(otf|ttf|woff2?|ttc|otc)$/i;
export const FONT_ACCEPT = ".otf,.ttf,.woff,.woff2,.ttc,.otc";

/** Tells every page of this browser that the shared fonts changed. */
export function fontsChannel(): BroadcastChannel {
  return new BroadcastChannel("publr-design-fonts");
}

async function fontsDir(): Promise<FileSystemDirectoryHandle> {
  return (await root()).getDirectoryHandle("fonts", { create: true });
}

export async function listFonts(): Promise<SharedFont[]> {
  return (await readJson<SharedFont[]>(await fontsDir(), "index.json")) ?? [];
}

/** Every shared font's bytes, for an engine starting. */
export type FontFile = { id: string; bytes: Uint8Array; family?: string; style?: string };

export async function sharedFontBytes(): Promise<FontFile[]> {
  const dir = await fontsDir();
  const out: FontFile[] = [];
  for (const f of await listFonts()) {
    const bytes = await readBytes(dir, `${f.id}.${f.ext}`);
    if (bytes) out.push({ id: f.id, bytes, family: f.family, style: f.style });
  }
  return out;
}

let parser: Promise<Engine> | null = null;

/** An engine on this thread for reading font files (made once). */
function fontParser(): Promise<Engine> {
  parser ??= engineModule().then((m) => Engine.create(m));
  return parser;
}

async function sha256(bytes: Uint8Array): Promise<string> {
  const d = new Uint8Array(await crypto.subtle.digest("SHA-256", bytes as BufferSource));
  return Array.from(d, (x) => x.toString(16).padStart(2, "0")).join("");
}

export type AddResult = { added: SharedFont[]; failed: { name: string; error: string }[] };

/** Reads, checks and keeps font files; files already kept are skipped. */
export async function addFonts(files: { name: string; bytes: Uint8Array }[], source: SharedFont["source"]): Promise<AddResult> {
  const result: AddResult = { added: [], failed: [] };
  if (!files.length) return result;
  const engine = await fontParser();
  const dir = await fontsDir();
  const list = await listFonts();
  for (const f of files) {
    const ext = (f.name.match(FONT_FILES)?.[1] ?? "").toLowerCase();
    if (!ext) {
      result.failed.push({ name: f.name, error: "not a font file" });
      continue;
    }
    let info: FontInfo;
    try {
      info = engine.fontInfo(f.bytes);
    } catch (err) {
      result.failed.push({ name: f.name, error: err instanceof Error ? err.message : String(err) });
      continue;
    }
    const id = await sha256(f.bytes);
    if (list.some((x) => x.id === id)) continue;
    await writeBytes(dir, `${id}.${ext}`, f.bytes);
    const font: SharedFont = { id, ext, name: f.name, source, added: Date.now(), bytes: f.bytes.length, faces: info.faces, axes: info.axes };
    if (!info.faces.length || !info.faces.every((x) => named(x.family))) {
      const n = nameFromFile(f.name);
      font.family = n.family;
      font.style = n.style;
      font.faces = info.faces.map((x) => ({ ...x, family: n.family, style: n.style }));
    }
    list.push(font);
    result.added.push(font);
  }
  if (result.added.length) {
    await writeJson(dir, "index.json", list);
    const ch = fontsChannel();
    ch.postMessage({ type: "added", ids: result.added.map((f) => f.id) });
    ch.close();
  }
  return result;
}

/** Removes a shared font; open files keep it until they are opened again. */
export async function removeFont(id: string): Promise<void> {
  const dir = await fontsDir();
  const list = await listFonts();
  const f = list.find((x) => x.id === id);
  if (!f) return;
  await dir.removeEntry(`${f.id}.${f.ext}`).catch(() => {});
  await writeJson(
    dir,
    "index.json",
    list.filter((x) => x.id !== id),
  );
  const ch = fontsChannel();
  ch.postMessage({ type: "removed", ids: [id] });
  ch.close();
}

/** A shared font's bytes and the names it goes by. */
export async function fontBytes(id: string): Promise<FontFile | null> {
  const f = (await listFonts()).find((x) => x.id === id);
  if (!f) return null;
  const bytes = await readBytes(await fontsDir(), `${f.id}.${f.ext}`);
  return bytes ? { id, bytes, family: f.family, style: f.style } : null;
}

// ------------------------------------------------------------------ installed fonts

type LocalFont = { family: string; fullName: string; postscriptName: string; style: string; blob(): Promise<Blob> };

/** Whether this browser can read the computer's installed fonts. */
export const canUseLocalFonts = () => typeof window !== "undefined" && "queryLocalFonts" in window;

/** Keeps the installed fonts of `families` (all asked, case-insensitive) as shared fonts.
 * Asks for permission: call from a click. */
export async function addLocalFonts(families: string[]): Promise<AddResult> {
  const query = (window as unknown as { queryLocalFonts(): Promise<LocalFont[]> }).queryLocalFonts;
  const all = await query.call(window);
  const want = new Set(families.map((f) => f.toLowerCase()));
  const files: { name: string; bytes: Uint8Array }[] = [];
  const seen = new Set<string>();
  for (const f of all) {
    if (!want.has(f.family.toLowerCase())) continue;
    const blob = await f.blob();
    const bytes = new Uint8Array(await blob.arrayBuffer());
    const key = `${bytes.length}:${f.postscriptName}`;
    if (seen.has(key)) continue;
    seen.add(key);
    // A file holding a collection is read for its first face; the type is told by bytes.
    const tag = String.fromCharCode(...bytes.slice(0, 4));
    files.push({ name: `${f.postscriptName}.${tag === "OTTO" ? "otf" : tag === "ttcf" ? "ttc" : "ttf"}`, bytes });
  }
  return addFonts(files, "local");
}

// ------------------------------------------------------------------ Google Fonts

const GOOGLE = "https://raw.githubusercontent.com/google/fonts/main";

function missKey(family: string): string {
  return `publr-design-google-miss:${family.toLowerCase()}`;
}

/** Fetches family `family` from Google Fonts' repository (full builds, every file its
 * METADATA.pb lists) and keeps it; null when Google Fonts has no such family. A family
 * not found is not asked for again for a week. */
export async function addGoogleFamily(family: string): Promise<AddResult | null> {
  try {
    const miss = Number(localStorage.getItem(missKey(family)) ?? 0);
    if (miss && Date.now() - miss < 7 * 86400000) return null;
  } catch {
    // No storage: ask every time.
  }
  const dirName = family.toLowerCase().replace(/[^a-z0-9]/g, "");
  for (const license of ["ofl", "apache", "ufl"]) {
    const r = await fetch(`${GOOGLE}/${license}/${dirName}/METADATA.pb`).catch(() => null);
    if (!r || !r.ok) continue;
    const meta = await r.text();
    const names = [...new Set([...meta.matchAll(/filename:\s*"([^"]+)"/g)].map((x) => x[1]))];
    const files: { name: string; bytes: Uint8Array }[] = [];
    for (const name of names) {
      const fr = await fetch(`${GOOGLE}/${license}/${dirName}/${encodeURIComponent(name).replace(/%5B/g, "[").replace(/%5D/g, "]").replace(/%2C/g, ",")}`).catch(() => null);
      if (fr && fr.ok) files.push({ name, bytes: new Uint8Array(await fr.arrayBuffer()) });
    }
    if (files.length) return addFonts(files, "google");
  }
  try {
    localStorage.setItem(missKey(family), String(Date.now()));
  } catch {
    // No storage.
  }
  return null;
}
