// A project's workspace, after the desktop app's tabs: the design system's tab first
// (fixed: it cannot close or move), then a tab per file open, each a whole Design mode
// canvas. On the design system's tab one file is its reference, drawn picture-in-picture
// over the design system canvas (moved by its header, resized by its corners and edges,
// collapsed back to the selector in the corner); "Edit" opens the reference in its own tab.
//
// There is one viewer: it shows the reference on the design system's tab and the file on
// a file's tab. Every file open stays open in it (Viewer.ptsx: an engine each, its
// page, camera, selection and undo), so going between tabs is a switch, not an open;
// past a memory budget the least recently shown are parked (saved, let go, opened again
// from their file when shown, their view put back). Each tab remembers its page.
//
// Kept in OPFS (`design-systems/<project>.workspace.json`): the tabs, the reference, the
// picture-in-picture's place, and each file's view (page and every page's camera).
//
// Glue, not UI.

import { Publr } from "publr-jsx";
import { importFiles } from "../home/importer";
import { readJson, root, SERVED_ID, writeJson } from "../home/store";
import { navigate, route, toast } from "../app/route";
import { choosePage, forgetFile, state as viewer, viewMemory } from "../viewer/Viewer.ptsx";
import type { KeptView } from "../viewer/stage";
import { refreshFiles, sys } from "./store";

/** A file's view as kept: its page and each page's camera (`[page, x, y, z]`). */
type SavedView = { page: number; cams: number[][] };

type Saved = {
  tabs: { id: string; page: string }[];
  reference: { file: string; page: string };
  pip: { open: boolean; x: number; y: number; w: number; h: number };
  views?: Record<string, SavedView>;
};

/** Each file's view, by id (kept with the tabs). */
let views: Record<string, SavedView> = {};

function toSaved(v: KeptView): SavedView {
  const cams: number[][] = [];
  for (const [page, c] of v.cameras) cams.push([page, c.x, c.y, c.z]);
  return { page: v.page, cams };
}

function fromSaved(v: SavedView): KeptView | null {
  const cameras = new Map(v.cams.map((c) => [c[0], { x: c[1], y: c[2], z: c[3] }]));
  const cam = cameras.get(v.page);
  return cam ? { page: v.page, cam, cameras, selected: null } : null;
}

// The viewer keeps each file's view here while the workspace is open: the camera of every
// page comes back with the file, after a reload too.
viewMemory.get = (id) => (loaded && views[id] ? fromSaved(views[id]) : null);
viewMemory.put = (id, v) => {
  if (!loaded || !(ws.tabs.some((t) => t.id === id) || ws.reference.file === id)) return;
  const next = toSaved(v);
  const was = views[id];
  if (was && JSON.stringify(was) === JSON.stringify(next)) return;
  views = { ...views, [id]: next };
  save();
};
// The file shown and the reference stay open whatever the memory (the other tab's file
// is the one parked first).
viewMemory.keep = () => [ws.reference.file, route.tab === "file" ? route.fileId : ""].filter(Boolean);

/** The picture-in-picture's header, px. */
export const PIP_HEADER = 32;
/** Its least size, px. */
const PIP_MIN_W = 240;
const PIP_MIN_H = 160;
/** Room kept below it for the reference selector, px. */
const SELECTOR_ROOM = 56;

export const ws = Publr.reactive({
  /** The project these tabs are of ("" while none is loaded). */
  project: "",
  /** The files open as tabs, in their order, with the page each shows. */
  tabs: [] as { id: string; name: string; page: string }[],
  /** The design system tab's reference ("" none) and its page. */
  reference: { file: "", page: "" },
  /** The picture-in-picture, in px from the design system canvas's top left (w 0: not
   * placed yet). */
  pip: { open: true, x: 0, y: 0, w: 0, h: 0 },
  /** The design system canvas's box in the workspace (its left, top, width, height). */
  area: { left: 0, top: 0, width: 0, height: 0 },
  /** The reference picker's open state is the dropdown's; the import's progress. */
  importing: "",
});

const dir = async () => (await root()).getDirectoryHandle("design-systems", { create: true });

let loaded = "";
let saveTimer = 0;

function save(): void {
  const project = ws.project;
  if (!project || loaded !== project) return;
  const data: Saved = {
    tabs: ws.tabs.map((t) => ({ id: t.id, page: t.page })),
    reference: { ...ws.reference },
    pip: { ...ws.pip },
    views,
  };
  window.clearTimeout(saveTimer);
  saveTimer = window.setTimeout(() => {
    void dir()
      .then((d) => writeJson(d, `${project}.workspace.json`, data))
      .catch((err) => console.error("workspace: not saved", err));
  }, 300);
}

/** A file's name as the browser lists it. */
export function fileName(id: string): string {
  return sys.files.find((f) => f.id === id)?.name ?? (id === SERVED_ID ? "pe view" : id);
}

function names(): void {
  ws.tabs = ws.tabs.map((t) => ({ ...t, name: fileName(t.id) }));
}

/** Loads project `project`'s tabs (`reference`: the reference when it has none yet). */
export async function openWorkspace(project: string, reference = ""): Promise<void> {
  if (ws.project === project && loaded === project) return;
  ws.project = project;
  const kept = await readJson<Saved>(await dir(), `${project}.workspace.json`).catch(() => null);
  await refreshFiles();
  const exists = (id: string) => sys.files.some((f) => f.id === id);
  ws.tabs = (kept?.tabs ?? []).filter((t) => exists(t.id)).map((t) => ({ id: t.id, name: fileName(t.id), page: t.page }));
  const ref = kept?.reference?.file && exists(kept.reference.file) ? kept.reference : { file: reference && exists(reference) ? reference : "", page: "" };
  ws.reference = { file: ref.file, page: ref.page };
  if (kept?.pip) ws.pip = { ...kept.pip };
  views = kept?.views ?? {};
  loaded = project;
  // The address names the tab; the design system's names its reference too.
  if (route.tab === "system" && !route.fileId && ws.reference.file) showSystemTab(true);
  else if (route.tab === "system" && route.fileId && route.fileId !== ws.reference.file && exists(route.fileId)) ws.reference = { file: route.fileId, page: "" };
  else if (route.tab === "file" && route.fileId && !ws.tabs.some((t) => t.id === route.fileId)) ws.tabs = [...ws.tabs, { id: route.fileId, name: fileName(route.fileId), page: "" }];
  save();
}

const base = () => `/system/${encodeURIComponent(ws.project)}`;

/** The design system's tab (its reference beside it). */
export function showSystemTab(replace = false): void {
  if (!ws.project) return;
  const to = ws.reference.file ? `${base()}?ref=${encodeURIComponent(ws.reference.file)}` : base();
  if (replace) {
    history.replaceState(null, "", to);
    navigate(to);
  } else navigate(to);
}

/** File `id`'s tab, opened when it is not yet. */
export function showFileTab(id: string, page = ""): void {
  if (!ws.project || !id) return;
  if (!ws.tabs.some((t) => t.id === id)) ws.tabs = [...ws.tabs, { id, name: fileName(id), page }];
  else if (page) ws.tabs = ws.tabs.map((t) => (t.id === id ? { ...t, page } : t));
  save();
  navigate(`${base()}/file/${encodeURIComponent(id)}`);
}

/** Closes file `id`'s tab (the one before it shows, or the design system). */
export function closeTab(id: string): void {
  const at = ws.tabs.findIndex((t) => t.id === id);
  if (at < 0) return;
  ws.tabs = ws.tabs.filter((t) => t.id !== id);
  // Its document lets go, unless it is the reference too.
  if (ws.reference.file !== id) {
    const { [id]: _gone, ...rest } = views;
    void _gone;
    views = rest;
    forgetFile(id);
  }
  save();
  if (route.tab === "file" && route.fileId === id) {
    const prev = ws.tabs[at - 1] ?? ws.tabs[at];
    if (prev) showFileTab(prev.id);
    else showSystemTab();
  }
}

/** Shows file `id` as the design system's reference (its first page, or `page`). */
export function setReference(id: string, page = ""): void {
  ws.reference = { file: id, page };
  ws.pip = { ...ws.pip, open: true };
  save();
  showSystemTab();
}

/** The reference's page. */
export function setReferencePage(index: number): void {
  ws.reference = { ...ws.reference, page: String(index) };
  save();
  if (route.tab === "system" && viewer.fileId === ws.reference.file) choosePage(String(index));
}

export function togglePip(open = !ws.pip.open): void {
  ws.pip = { ...ws.pip, open };
  save();
}

/** "Edit": the reference in its own tab, on the page it shows. */
export function editReference(): void {
  if (!ws.reference.file) return;
  showFileTab(ws.reference.file, viewer.fileId === ws.reference.file ? viewer.page : ws.reference.page);
}

/** Imports `.fig`/`.pubd` files into the project and opens the first as a tab. */
export async function importIntoProject(files: File[]): Promise<void> {
  if (!files.length || !ws.project) return;
  ws.importing = "Importing…";
  try {
    const r = await importFiles(files, ws.project, (text) => {
      ws.importing = text;
      toast(text);
    });
    route.files++;
    await refreshFiles();
    const failed = r.failed.map((f) => `${f.name}: ${f.error}`).join("; ");
    toast(failed ? `Not imported: ${failed}` : r.done.length === 1 ? `Imported ${r.done[0].name}` : `Imported ${r.done.length} files`, failed ? 8000 : 3000);
    if (r.done.length) showFileTab(r.done[0].id);
  } catch (err) {
    toast(`Import failed: ${err instanceof Error ? err.message : String(err)}`, 8000);
  } finally {
    ws.importing = "";
  }
}

// ------------------------------------------------------------ the page each tab shows

/** The page the tab shown wants, once its file is open ("" any). */
function wantedPage(): string {
  if (route.tab === "file") return ws.tabs.find((t) => t.id === route.fileId)?.page ?? "";
  return route.fileId === ws.reference.file ? ws.reference.page : "";
}

let settled = "";

/** Follows the viewer: the tab's page shown once its file is open, and the page then
 * chosen kept for the tab. (An effect the shell runs.) */
export function followPages(): void {
  const key = `${route.system}|${route.tab}|${route.fileId}`;
  const open = !!route.system && viewer.fileId === route.fileId && viewer.pages.length > 0;
  const page = viewer.page;
  if (!open) return;
  Publr.untrack(() => {
    if (settled !== key) {
      settled = key;
      const want = wantedPage();
      if (want && want !== page && Number(want) < viewer.pages.length) {
        choosePage(want);
        return;
      }
    }
    if (route.tab === "file") {
      const t = ws.tabs.find((x) => x.id === route.fileId);
      if (t && t.page !== page) {
        ws.tabs = ws.tabs.map((x) => (x.id === route.fileId ? { ...x, page } : x));
        save();
      }
    } else if (route.fileId === ws.reference.file && ws.reference.page !== page) {
      ws.reference = { ...ws.reference, page };
      save();
    }
  });
}

/** Keeps the tab names as the files are named (an effect the shell runs). */
export function followNames(): void {
  void sys.files;
  Publr.untrack(() => names());
}

// ------------------------------------------------------------ the picture-in-picture

/** Where it is now: placed bottom right at 30 % of the window's width, 4:3, the first
 * time; kept inside the design system canvas. */
export function pipBox(): { x: number; y: number; w: number; h: number } {
  const a = ws.area;
  let { x, y, w, h } = ws.pip;
  if (!w) {
    w = Math.round(window.innerWidth * 0.3);
    h = Math.round((w * 3) / 4) + PIP_HEADER;
    x = a.width - w - 16;
    y = a.height - h - SELECTOR_ROOM;
  }
  w = Math.max(PIP_MIN_W, Math.min(w, Math.max(PIP_MIN_W, a.width - 16)));
  h = Math.max(PIP_MIN_H, Math.min(h, Math.max(PIP_MIN_H, a.height - 16)));
  x = Math.max(8, Math.min(x, a.width - w - 8));
  y = Math.max(8, Math.min(y, a.height - h - 8));
  return { x, y, w, h };
}

/** The style that puts the viewer's box there. */
export function pipStyle(): string {
  const b = pipBox();
  return `left:${ws.area.left + b.x}px;top:${ws.area.top + b.y}px;width:${b.w}px;height:${b.h}px`;
}

type Edge = "move" | "n" | "s" | "e" | "w" | "ne" | "nw" | "se" | "sw";

/** A press on the header (moves it) or a corner or edge (resizes it). */
export function pipPress(e: PointerEvent, edge: Edge): void {
  if (e.button !== 0) return;
  if (edge === "move" && e.target instanceof Element && e.target.closest("button, [role=menu]")) return;
  e.preventDefault();
  e.stopPropagation();
  const start = pipBox();
  const x0 = e.clientX;
  const y0 = e.clientY;
  const move = (m: PointerEvent) => {
    const dx = m.clientX - x0;
    const dy = m.clientY - y0;
    let { x, y, w, h } = start;
    if (edge === "move") {
      x += dx;
      y += dy;
    } else {
      if (edge.includes("e")) w = start.w + dx;
      if (edge.includes("s")) h = start.h + dy;
      if (edge.includes("w")) {
        w = Math.max(PIP_MIN_W, start.w - dx);
        x = start.x + start.w - w;
      }
      if (edge.includes("n")) {
        h = Math.max(PIP_MIN_H, start.h - dy);
        y = start.y + start.h - h;
      }
      w = Math.max(PIP_MIN_W, w);
      h = Math.max(PIP_MIN_H, h);
    }
    ws.pip = { ...ws.pip, x, y, w, h };
  };
  const up = () => {
    window.removeEventListener("pointermove", move);
    window.removeEventListener("pointerup", up);
    window.removeEventListener("pointercancel", up);
    ws.pip = { ...ws.pip, ...pipBox() };
    save();
  };
  window.addEventListener("pointermove", move);
  window.addEventListener("pointerup", up);
  window.addEventListener("pointercancel", up);
}

/** The design system canvas's box, measured by its host (SystemView). */
export function measureArea(el: HTMLElement): void {
  const next = { left: el.offsetLeft, top: el.offsetTop, width: el.offsetWidth, height: el.offsetHeight };
  const a = ws.area;
  if (next.width && (a.left !== next.left || a.top !== next.top || a.width !== next.width || a.height !== next.height)) ws.area = next;
}
