// What Content mode's chrome shows, as one plain store: the page, the breakpoint view, the
// tool, the zoom, the selection and what the right panel reads about it, the document's
// state. The canvas (canvas.ts) writes it; the panels render it and call the canvas back.
import { Publr } from "publr-jsx";
import type { DeviceKey } from "./breakpoints";
import type { DocEntry } from "./documents";
import type { Format, TextKind } from "./frames";

export type FieldRow = { key: string; label: string; icon: string; kind: string; preview: string; selected: boolean };

/** The right panel's view of the selection. */
export type Inspector =
  | { kind: "page" }
  | { kind: "block"; key: string; title: string; icon: string; pattern: boolean; description: string; rows: FieldRow[] }
  | {
      kind: "field";
      key: string;
      title: string;
      icon: string;
      description: string;
      block: string;
      blockTitle: string;
      text: TextKind | null;
      formats: Format[];
      image: boolean;
      src: string;
      alt: string;
      link: boolean;
      href: string;
    }
  | { kind: "many"; count: number; title: string };

/** A List View row: a template part, the content slot, a block, a field. */
export type LayerRow = { key: string; label: string; detail: string; icon: string; depth: number; selected: boolean; open: boolean; hasChildren: boolean; kind: "part" | "slot" | "block" | "field" };

export type Crumb = { key: string; label: string };
export type Heading = { key: string; level: string; text: string; guide: number };

export const view = Publr.reactive({
  docKey: "",
  title: "",
  location: "",
  template: "",
  loading: true,
  error: "",
  docs: [] as DocEntry[],
  /** The breakpoint shown alone, or every one side by side (`all`). */
  /** The breakpoint shown; "" is free responsive mode (any width, `freeWidth`). */
  device: "desktop" as DeviceKey | "",
  freeWidth: 1024,
  /** The breakpoint each device last showed (its button goes back to it). */
  lastBreakpoint: {} as Record<string, string>,
  all: false,
  /** Fit: the camera is locked and the frames fill the canvas's width (never above 100%). */
  fit: false,
  /** Where a style edit would land: the breakpoint picked, the one the free width falls
   * in, or (all side by side) the frame the selection is in. */
  editingBreakpoint: "desktop" as DeviceKey,
  tool: "move" as "move" | "hand",
  zoomLabel: "100%",
  selection: [] as string[],
  editing: "",
  inspector: { kind: "page" } as Inspector,
  layers: [] as LayerRow[],
  /** Rows the List View shows folded. */
  collapsed: [] as string[],
  breadcrumb: [] as Crumb[],
  outline: { characters: 0, words: 0, minutes: 1, headings: [] as Heading[] },
  /** The left panel: the inserter, the list view, or none; and each one's tab. */
  left: "" as "" | "inserter" | "list",
  inserterTab: "blocks" as "blocks" | "patterns" | "media",
  listTab: "list" as "list" | "outline" | "patterns",
  query: "",
  shelves: [] as { category: string; label: string; items: { type: string; label: string; icon: string }[] }[],
  patterns: [] as { name: string; label: string; description: string; category: string }[],
  sidebar: "document" as "document" | "block",
  sidebarOpen: true,
  output: false,
  outputEditing: "",
  outputData: "",
  /** The block toolbar over the selection, CSS px in the canvas (shown: false while none). */
  toolbar: { shown: false, x: 0, y: 0 },
  canUndo: false,
  canRedo: false,
  /** Steps made since the page opened (undo counts back). */
  edits: 0,
  uiHidden: false,
  notice: "",
});

const PREF = "pd-content-view";

/** The breakpoint view this browser last chose. */
export function readViewPref(): void {
  try {
    const saved = JSON.parse(localStorage.getItem(PREF) ?? "{}") as { device?: string; all?: boolean; left?: string; sidebarOpen?: boolean; fit?: boolean; freeWidth?: number; lastBreakpoint?: Record<string, string> };
    if (saved.device === "mobile" || saved.device === "tablet" || saved.device === "desktop" || saved.device === "xl" || saved.device === "") view.device = saved.device;
    if (typeof saved.freeWidth === "number" && saved.freeWidth > 0) view.freeWidth = saved.freeWidth;
    view.fit = saved.fit === true;
    if (saved.lastBreakpoint && typeof saved.lastBreakpoint === "object") view.lastBreakpoint = saved.lastBreakpoint;
    view.all = saved.all === true;
    if (saved.left === "inserter" || saved.left === "list" || saved.left === "") view.left = saved.left;
    if (typeof saved.sidebarOpen === "boolean") view.sidebarOpen = saved.sidebarOpen;
  } catch {
    // The default view.
  }
}

export function saveViewPref(): void {
  try {
    localStorage.setItem(PREF, JSON.stringify({ device: view.device, freeWidth: view.freeWidth, lastBreakpoint: view.lastBreakpoint, all: view.all, fit: view.fit, left: view.left, sidebarOpen: view.sidebarOpen }));
  } catch {
    // Kept for this visit only.
  }
}
