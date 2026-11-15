// Importing files: one engine worker for the batch (import-worker.ts), stopped after, so
// its memory goes back as soon as the files are in OPFS.

import { startWorkers } from "../viewer/loader";
import { newId } from "./store";
import type { FileMeta } from "./store";

/** The files the import takes: `.fig`, and `.pubd` (a zip; `.zip` too). */
export const IMPORTABLE = /\.(fig|pubd|zip)$/i;

/** A file's name without its extension: the file's name in the browser. */
export const stem = (name: string) => name.replace(/\.(fig|pubd|zip)$/i, "") || name;

export type ImportResult = { done: FileMeta[]; failed: { name: string; error: string }[] };

/** Imports `files` into `project` (null: Drafts), reporting progress as it goes. */
export async function importFiles(files: File[], project: string | null, progress: (text: string) => void): Promise<ImportResult> {
  const result: ImportResult = { done: [], failed: [] };
  const take = files.filter((f) => IMPORTABLE.test(f.name));
  for (const f of files) if (!IMPORTABLE.test(f.name)) result.failed.push({ name: f.name, error: "not a .fig or .pubd file" });
  if (!take.length) return result;
  const pool = await startWorkers(1, (text) => text && progress(text), new URL("./import-worker.js", import.meta.url));
  pool.onNote = (text) => {
    if (text.startsWith("engine memory")) console.info(`import: ${text}`);
    else progress(text);
  };
  try {
    for (const file of take) {
      const name = stem(file.name);
      progress(`Importing ${name}…`);
      try {
        const t0 = performance.now();
        const r = await pool.call(pool.slots[0], { type: "import", fileId: newId(), name, project, file });
        console.info(`import: ${file.name} (${Math.round(file.size / 1048576)} MB) in ${Math.round(performance.now() - t0)} ms`);
        result.done.push(r.meta as FileMeta);
      } catch (err) {
        result.failed.push({ name: file.name, error: err instanceof Error ? err.message : String(err) });
      }
    }
  } finally {
    pool.terminate();
  }
  return result;
}
