// Where the app is, as a plain store every screen reads: `/` is the file browser,
// `/content/<doc>` a page in Content mode, `/file/<id>` a file in the viewer (the history API; a reload lands back on the same
// file). Screens react to it in their own effects; nothing calls into a screen.
//
// Also the app-wide toast, and imports (which run whichever screen shows).
import { Publr } from "publr-jsx";
import { importFiles } from "../home/importer";

export const route = Publr.reactive({
  screen: "home" as "home" | "file" | "content",
  /** The file the viewer shows ("" on the file browser). */
  fileId: "",
  /** The page Content mode shows ("" elsewhere). */
  contentDoc: "",
  /** Bumped when files change from outside the file browser (an import finished). */
  files: 0,
  /** The toast's text ("" while none shows). */
  toast: "",
  /** The file browser's view the address names (`/fonts`: "fonts"; "" otherwise). */
  homeView: "",
  /** The project whose workspace shows (`/system/<project>…`; "" while none): its
   * design system tab and the files open as tabs beside it. */
  system: "",
  /** In a project's workspace, the tab shown: its design system (the file the viewer
   * shows is the reference, `?ref=<id>`, drawn picture-in-picture) or a file. */
  tab: "system" as "system" | "file",
  /** The node the address linked to when it was opened (`?node-id=`, "" none): read
   * here, before the file opens, because the editor rewrites the address as it does. The
   * viewer takes it when it opens the file. */
  link: "",
});

let toastTimer = 0;

/** Shows `text` in the toast; it goes after `ms` (0: it stays until the next one). */
export function toast(text: string, ms = 0): void {
  window.clearTimeout(toastTimer);
  route.toast = text;
  if (ms) toastTimer = window.setTimeout(() => (route.toast = ""), ms);
}

function apply(path: string): void {
  const m = /^\/file\/([^/]+)\/?$/.exec(path);
  const c = /^\/content\/([^/]+)\/?$/.exec(path);
  // A project's workspace: `/system/<project>` (its design system, the reference beside
  // it as `?ref=`) or `/system/<project>/file/<id>` (a file's tab).
  const w = /^\/system\/([^/]+)(?:\/file\/([^/]+))?\/?$/.exec(path);
  const query = new URLSearchParams(location.search);
  route.fileId = m ? decodeURIComponent(m[1]) : w ? decodeURIComponent(w[2] ?? query.get("ref") ?? "") : "";
  route.contentDoc = c ? decodeURIComponent(c[1]) : "";
  route.screen = m || w ? "file" : c ? "content" : "home";
  route.homeView = path === "/fonts" ? "fonts" : "";
  route.system = w ? decodeURIComponent(w[1]) : "";
  route.tab = w && w[2] ? "file" : "system";
  route.link = query.get("node-id") ?? "";
}

/** Goes to `path` (it may carry a query: `/system/<project>?ref=<id>`). */
export function navigate(path: string): void {
  if (path !== location.pathname + location.search) history.pushState(null, "", path);
  apply(location.pathname);
}

export function openFileRoute(id: string): void {
  navigate(`/file/${encodeURIComponent(id)}`);
}

// The address's screen from the first render: a file's address never draws the file
// browser first.
if (typeof location !== "undefined") apply(location.pathname);

/** Starts on the route the address names and follows back and forward. */
export function startRouting(): void {
  window.addEventListener("popstate", () => apply(location.pathname));
  apply(location.pathname);
}

/** Imports files into a project (null: Drafts), the toast telling how it goes; opens
 * the first one when `open`. */
export async function importAndShow(files: File[], project: string | null, open: boolean): Promise<void> {
  try {
    const r = await importFiles(files, project, (text) => toast(text));
    const failed = r.failed.map((f) => `${f.name}: ${f.error}`).join("; ");
    const done = r.done.length === 1 ? `Imported ${r.done[0].name}` : `Imported ${r.done.length} files`;
    toast(failed ? (r.done.length ? `${done}. Not imported: ${failed}` : `Not imported: ${failed}`) : done, failed ? 8000 : 3000);
    route.files++;
    if (open && r.done.length) openFileRoute(r.done[0].id);
  } catch (err) {
    toast(`Import failed: ${err instanceof Error ? err.message : String(err)}`, 8000);
  }
}
