// What Content mode's chrome asks of the canvas. The canvas and the documents (with the
// block editor's model under them) are loaded when Content mode first opens, never with
// the app: the file browser and Design mode do not wait for them or depend on them.
import type { DeviceKey } from "./breakpoints";
import { navigate } from "../app/route";
import type { ContentCanvas } from "./canvas";
import type { Format } from "./frames";
import { DEVICES } from "./breakpoints";
import { readViewPref, saveViewPref, view } from "./store";

let canvas: ContentCanvas | null = null;
let opened = "";

type Modules = { canvas: typeof import("./canvas"); documents: typeof import("./documents") };
let modules: Promise<Modules> | null = null;

function load(): Promise<Modules> {
  modules ??= Promise.all([import("./canvas"), import("./documents")]).then(([c, d]) => ({ canvas: c, documents: d }));
  return modules;
}

/** The canvas host is on screen: the canvas is made in it. */
export async function attach(host: HTMLElement): Promise<void> {
  if (canvas?.host === host) return;
  readViewPref();
  const m = await load();
  canvas?.dispose();
  canvas = new m.canvas.ContentCanvas(host);
  canvas.onPickImage = (key) => pickImage(key);
  const w = window as unknown as { pdContent?: ContentCanvas };
  w.pdContent = canvas;
  opened = "";
  view.docs = await m.documents.documents();
  const lib = await m.documents.library();
  view.shelves = lib.shelves;
  view.patterns = lib.patterns;
}

export function detach(): void {
  canvas?.dispose();
  canvas = null;
  opened = "";
}

/** Opens page `key` (from the address) once the canvas is there. */
export async function openDoc(key: string): Promise<void> {
  if (!canvas || !key || opened === key) return;
  opened = key;
  view.loading = true;
  view.error = "";
  const m = await load();
  const page = await m.documents.loadDocument(key);
  if (!page) {
    view.error = `There is no page "${key}".`;
    view.loading = false;
    return;
  }
  view.docKey = key;
  view.title = page.title;
  view.location = page.location;
  view.template = page.template;
  document.title = `${page.title} · Content · PublrDesign`;
  await canvas.open(page);
  view.loading = false;
}

export const showDoc = (key: string) => navigate(`/content/${encodeURIComponent(key)}`);

/** A breakpoint picked from a device's menu: that breakpoint alone (never a toggle). */
export function pickBreakpoint(key: DeviceKey): void {
  const d = DEVICES.find((b) => b.key === key);
  if (!d) return;
  view.lastBreakpoint = { ...view.lastBreakpoint, [d.device]: key };
  view.device = key;
  view.all = false;
  saveViewPref();
  void canvas?.rebuild();
}

/** A device's button: the breakpoint it last showed (or its first). Pressed again while
 * it shows: free responsive mode at that width (any width, dragged by the handles). */
export function setDevice(group: string): void {
  const list = DEVICES.filter((d) => d.device === group);
  const current = list.find((d) => d.key === view.device);
  if (!view.all && current) {
    view.freeWidth = current.width;
    view.device = "";
    saveViewPref();
    void canvas?.rebuild();
    return;
  }
  const last = list.find((d) => d.key === view.lastBreakpoint[group]) ?? list[0];
  if (last) pickBreakpoint(last.key as DeviceKey);
}

export function setAll(): void {
  view.all = !view.all;
  saveViewPref();
  void canvas?.rebuild();
}

/** The Fit toggle: the camera held with the frames across the canvas. */
export const toggleFit = () => canvas?.setFit(!view.fit);
export const zoom100 = () => canvas?.zoom100();

export const fitWidth = () => canvas?.fitWidth();
export const zoomBy = (f: number) => canvas?.zoomBy(f);
export const zoomTo = (z: number) => canvas?.zoomTo(z);
export const undo = () => canvas?.undo();
export const redo = () => canvas?.redo();
export const selectKey = (key: string) => canvas?.select([key]);
export const hoverKey = (key: string) => canvas?.hoverKey(key);
export const back = () => canvas?.up();

/** Edit the field's text on the canvas, all of it selected (the panel's Edit text). */
export function editKey(key: string): void {
  if (!canvas) return;
  canvas.select([key]);
  canvas.down();
}

export function setLink(key: string, href: string): void {
  canvas?.setAttrs(key, { href });
}

export function setAlt(key: string, alt: string): void {
  canvas?.setAttrs(key, { alt });
}

/** Options → Show wire output: the document as both pipelines write it, under the canvas. */
export function toggleOutput(): void {
  view.output = !view.output;
  if (view.output) canvas?.writeOutput();
}

/** Options → Copy editing HTML / Copy data HTML. */
export async function copyHtml(pipeline: "editing" | "data"): Promise<void> {
  if (!canvas) return;
  canvas.writeOutput();
  try {
    await navigator.clipboard.writeText(pipeline === "editing" ? view.outputEditing : view.outputData);
    notify(pipeline === "editing" ? "Copied the editing HTML" : "Copied the data HTML");
  } catch {
    notify("The clipboard is not available here");
  }
}

let noticeTimer = 0;

/** A short note at the bottom of the canvas. */
export function notify(text: string): void {
  window.clearTimeout(noticeTimer);
  view.notice = text;
  noticeTimer = window.setTimeout(() => (view.notice = ""), 3200);
}

/** What later prototypes bring, said where it is asked for. */
export const later = (what: string) => notify(`${what} comes in a later prototype`);

export function toggleLeft(panel: "inserter" | "list"): void {
  view.left = view.left === panel ? "" : panel;
  saveViewPref();
}

export function closeLeft(): void {
  view.left = "";
  saveViewPref();
}

export function toggleSidebar(): void {
  view.sidebarOpen = !view.sidebarOpen;
  saveViewPref();
}

export const format = (f: Format) => canvas?.format(f);
export const toggleRow = (key: string) => canvas?.toggleRow(key);

/** A List View row or an Outline heading picked. */
export function selectRow(key: string): void {
  if (!canvas || !key || key === "slot" || key.startsWith("part:")) {
    if (key.startsWith("part:")) later("Editing the template's parts");
    return;
  }
  canvas.select([key]);
}

/** The breadcrumb: Document clears the selection, a step selects it. */
export function selectPath(key: string): void {
  canvas?.select(key ? [key] : []);
}

export function preview(): void {
  if (!canvas) return;
  canvas.writeOutput();
  const page = window.open("", "_blank");
  if (!page) return;
  const frame = canvas.frames[0];
  const styles = [...(frame?.doc.querySelectorAll("link[rel=stylesheet], style") ?? [])].map((el) => el.outerHTML).join("");
  page.document.write(`<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>${view.title}</title>${styles}<body>${frame?.doc.querySelector("[data-pd-page]")?.outerHTML ?? ""}</body>`);
  page.document.close();
}

// ------------------------------------------------------------ the image file

let fileInput: HTMLInputElement | null = null;
let pickFor = "";

export function fileInputRef(el: HTMLInputElement | null): void {
  fileInput = el;
}

export function pickImage(key: string): void {
  pickFor = key;
  if (!fileInput) return;
  fileInput.value = "";
  fileInput.click();
}

export function filePicked(event: Event): void {
  const file = (event.currentTarget as HTMLInputElement).files?.[0];
  if (file && pickFor && canvas) canvas.setImage(pickFor, file);
}
