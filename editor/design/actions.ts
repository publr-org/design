// What the main menu lists, after Figma Design's: every item of every submenu, each an
// action with its key. The menu (MainMenu.ptsx), its Actions… search and the keys on the
// canvas (`actionKey`) all run the same actions from here, so a key the menu shows is the
// key that works. An item with nothing behind it yet has no `run`: it shows greyed, as
// Figma greys what does not apply. `enabled` greys one that does not apply now (Copy
// with nothing selected); `checked` is a toggle's tick.
//
// Keys are written as `Mod+Alt+Shift+KeyG` (event.code, Mod = Cmd or Ctrl). An action
// whose key another part handles (Cmd+Z in the viewer's editing, Shift+1, Shift+0, + and
// - in the viewer's canvas) names it in `shows` only.

import { Publr } from "publr-jsx";
import { navigate, openFileRoute, route, toast } from "../app/route";
import { createEmpty, duplicate as duplicateFile, SERVED_ID, updateMeta } from "../home/store";
import { feedOf } from "../viewer/feed";
import { shownFile, state as viewer, viewerEditing } from "../viewer/Viewer.ptsx";
import { ZipWriter } from "../home/zip";
import { liveEngine, typeOf } from "./doc";
import { openRequest } from "./requests";
import * as edits from "./edits";
import {
  clearSelection,
  currentTree,
  selectedInfos,
  setTheme,
  shell,
  showPage,
  toggleGuides,
  toggleMemory,
  toggleRulers,
  zoomBy,
  zoomFit,
  zoomSelection,
  zoomValue,
} from "./store";

export type Action = {
  id: string;
  label: string;
  /** The key that runs it from the canvas (or several). */
  key?: string | string[];
  /** The key shown, when another part handles it. */
  shows?: string;
  /** What it does; none: greyed, it is not built yet. */
  run?: () => void;
  /** Whether it applies now (read reactively by the menu). */
  enabled?: () => boolean;
  /** A toggle's state: the tick. */
  checked?: () => boolean;
  /** A feature not built yet (its key in the parity checklist): the item shows greyed,
   * and choosing it opens its feature request. */
  feature?: string;
};

/** A row of a menu: an action, a line between groups, or a submenu of actions. */
export type Entry = Action | "-" | { label: string; items: (Action | "-")[] };
export type Menu = { label: string; items: Entry[] };

// ------------------------------------------------------------ what applies

const has = () => shell.selection.length > 0;
// The engine and the read layers are not reactive: the shell's `ready` and `inspector`
// (set once a file opens and once the selection is read) are what the menu follows.
const editable = () => shell.ready && !!liveEngine();
const canEdit = () => editable() && has();
const infos = () => {
  void shell.inspector;
  return selectedInfos();
};
const texts = () => canEdit() && infos().some((i) => i.node.type === "text");
const types = () => {
  const t = currentTree();
  return shell.selection.map((id) => {
    const i = t.index.get(id);
    return i === undefined ? "" : typeOf(t, i);
  });
};
const browserFile = () => !!viewer.fileId && viewer.fileId !== SERVED_ID;

function undo(): void {
  try {
    viewerEditing()?.undo();
  } catch (err) {
    console.error("undo", err);
  }
}

function redo(): void {
  try {
    viewerEditing()?.redo();
  } catch (err) {
    console.error("redo", err);
  }
}

/** The selected layers as PNG files at 1x, as Figma's Export with its default setting. */
async function exportSelection(): Promise<void> {
  const e = liveEngine();
  if (!e) return;
  const names = infos().map((i) => ({ id: i.node.id, name: String(i.node.name ?? "Layer") }));
  for (const { id, name } of names) {
    try {
      await feedOf(e)?.node(id, 1);
      const px = e.renderNode(id, 1);
      if (!px.width || !px.height) continue;
      const canvas = new OffscreenCanvas(px.width, px.height);
      canvas.getContext("2d")?.putImageData(new ImageData(px.data, px.width, px.height), 0, 0);
      save(await canvas.convertToBlob({ type: "image/png" }), `${name}.png`);
    } catch (err) {
      console.error("export", err);
      toast(`${Publr.t("Could not export")} ${name}`, 4000);
    }
  }
}

/** The open file as a `.pubd` download: its document and pages as they are now (edits
 * included), the pages not loaded and the assets read from where it opened. */
async function saveLocalCopy(): Promise<void> {
  const f = shownFile();
  if (!f) return;
  const e = f.engine;
  toast(Publr.t("Saving a local copy…"), 60_000);
  try {
    const zip = new ZipWriter();
    await zip.add("document.json", e.saveDocument());
    const pages = e.pages().pages.length;
    for (let i = 0; i < pages; i++) {
      const p = e.pageFile(i);
      if (!p.src) continue;
      const bytes = p.loaded ? e.savePage(i) : await f.read(p.src);
      if (!bytes) throw new Error(`${p.src} is missing`);
      await zip.add(p.src, bytes);
    }
    for (const hash of e.assets()) {
      let bytes = await f.read(`assets/${hash}`);
      if (!bytes) {
        try {
          bytes = e.asset(hash);
        } catch {
          bytes = null;
        }
      }
      // An asset nowhere to be read is left out, as the file it opened from lacks it.
      if (bytes?.length) await zip.add(`assets/${hash}`, bytes);
      else console.warn(`save local copy: no asset ${hash}`);
    }
    save(zip.blob(), `${f.name.replace(/\.(fig|pubd|zip)$/i, "")}.pubd`);
    toast(Publr.t("Local copy saved"), 3000);
  } catch (err) {
    console.error("save local copy", err);
    toast(`${Publr.t("Could not save a local copy")}: ${err instanceof Error ? err.message : String(err)}`, 6000);
  }
}

/** Hands `blob` to the browser as a download named `name`. */
function save(blob: Blob, name: string): void {
  const url = URL.createObjectURL(blob);
  const a = Object.assign(document.createElement("a"), { href: url, download: name.replace(/[\\/:*?"<>|]/g, "-") });
  a.click();
  setTimeout(() => URL.revokeObjectURL(url), 10_000);
}

async function newDesignFile(): Promise<void> {
  const meta = await createEmpty(null);
  openFileRoute(meta.id);
}

async function duplicateThisFile(): Promise<void> {
  const copy = await duplicateFile(viewer.fileId);
  if (!copy) return;
  route.files++;
  toast(`${Publr.t("Duplicated to")} ${copy.name}`, 3000);
}

async function trashThisFile(): Promise<void> {
  await updateMeta(viewer.fileId, { trashed: Date.now() });
  route.files++;
  navigate("/");
}

function renameThisFile(): void {
  shell.uiHidden = false;
  shell.leftOpen = true;
  shell.leftTab = "file";
  shell.renamingFile = true;
}

/** The document's pages (the page list's rows, its dividers left out). */
const pageRows = () => shell.pages.filter((p) => !p.divider);

function stepPage(by: number): void {
  const rows = pageRows();
  const at = rows.findIndex((p) => p.current);
  if (rows.length > 1) showPage(rows[(at + by + rows.length) % rows.length].index);
}

// ------------------------------------------------------------ the menus

const CODE_GLYPHS: Record<string, string> = {
  Backspace: "⌫",
  Delete: "⌦",
  Equal: "+",
  Minus: "−",
  BracketLeft: "[",
  BracketRight: "]",
  Backslash: "\\",
  Slash: "/",
  Quote: "'",
  Period: ">",
  Comma: "<",
  PageUp: "PgUp",
  PageDown: "PgDn",
};

/** `Mod+Alt+Shift+KeyG` as the menu shows it: ⌥⇧⌘G (the Mac order ⌃⌥⇧⌘). */
export function glyphs(key: string): string {
  const parts = key.split("+");
  const code = parts.pop() ?? "";
  const mods = new Set(parts);
  const name = CODE_GLYPHS[code] ?? code.replace(/^Key|^Digit/, "");
  return `${mods.has("Ctrl") ? "⌃" : ""}${mods.has("Alt") ? "⌥" : ""}${mods.has("Shift") ? "⇧" : ""}${mods.has("Mod") ? "⌘" : ""}${name}`;
}


/** An item of a feature not built yet: greyed, its key shown, and choosing it opens the
 * request for `feature` (none: greyed only, a Figma product left out). */
const off = (id: string, label: string, key?: string, feature?: string): Action => ({ id, label, shows: key ? glyphs(key) : undefined, feature });

export const MENUS: Menu[] = [
  {
    label: "File",
    items: [
      { id: "new-design", label: "New design file", run: () => void newDesignFile() },
      off("new-whiteboard", "New whiteboard file"),
      off("new-presentation", "New presentation file"),
      "-",
      off("place-image", "Place image…", "Mod+Shift+KeyK", "tools/place-image-video"),
      off("import-file", "Import from file…", undefined, "files/import-files"),
      "-",
      { id: "save-local", label: "Save local copy…", run: () => void saveLocalCopy(), enabled: () => shell.ready && !!viewer.fileId },
      off("save-version", "Save to version history…", "Mod+Alt+KeyS", "files/named-versions"),
      off("version-history", "Show version history", undefined, "files/version-history"),
      "-",
      { id: "export", label: "Export…", key: "Mod+Shift+KeyE", run: () => void exportSelection(), enabled: canEdit },
      off("export-pdf", "Export frames to PDF…", undefined, "import-and-export/export-frames-to-pdf"),
      "-",
      { id: "duplicate-file", label: "Duplicate", run: () => void duplicateThisFile(), enabled: browserFile },
      { id: "rename-file", label: "Rename", run: renameThisFile, enabled: () => !viewer.readOnly && !!viewer.fileId },
      off("move-file", "Move to project…", undefined, "files/move-file"),
      { id: "trash-file", label: "Move to trash", run: () => void trashThisFile(), enabled: browserFile },
    ],
  },
  {
    label: "Edit",
    items: [
      { id: "undo", label: "Undo", shows: glyphs("Mod+KeyZ"), run: undo, enabled: editable },
      { id: "redo", label: "Redo", shows: glyphs("Mod+Shift+KeyZ"), run: redo, enabled: editable },
      "-",
      { id: "copy", label: "Copy", key: "Mod+KeyC", run: edits.copySelection, enabled: canEdit },
      { id: "cut", label: "Cut", key: "Mod+KeyX", run: edits.cutSelection, enabled: canEdit },
      { id: "paste", label: "Paste", key: "Mod+KeyV", run: edits.paste, enabled: () => editable() && edits.canPaste() },
      off("paste-over", "Paste over selection", "Mod+Shift+KeyV", "layers-and-selection/paste-over-selection"),
      off("paste-replace", "Paste to replace", "Mod+Shift+KeyR", "layers-and-selection/paste-to-replace"),
      { id: "duplicate", label: "Duplicate", key: "Mod+KeyD", run: edits.duplicate, enabled: canEdit },
      { id: "delete", label: "Delete", key: ["Backspace", "Delete"], run: edits.deleteSelection, enabled: canEdit },
      "-",
      off("copy-properties", "Copy properties", "Mod+Alt+KeyC", "layers-and-selection/copy-and-paste-properties"),
      off("paste-properties", "Paste properties", "Mod+Alt+KeyV", "layers-and-selection/copy-and-paste-properties"),
      off("pick-color", "Pick color", "KeyI", "tools/eyedropper"),
      "-",
      { id: "select-all", label: "Select all", key: "Mod+KeyA", run: edits.selectAll, enabled: editable },
      off("select-matching", "Select matching layers", "Mod+Alt+KeyA", "layers-and-selection/select-matching-layers"),
      { id: "select-none", label: "Select none", run: clearSelection, enabled: has },
      { id: "select-inverse", label: "Select inverse", key: "Mod+Shift+KeyA", run: edits.selectInverse, enabled: canEdit },
      "-",
      off("find-replace", "Find and replace…", "Mod+KeyF", "interface/find-and-replace"),
    ],
  },
  {
    label: "View",
    items: [
      off("pixel-grid", "Pixel grid", "Shift+Quote", "canvas/pixel-grid"),
      { id: "layout-guides", label: "Layout guides", key: "Shift+KeyG", run: toggleGuides, checked: () => shell.guides },
      { id: "rulers", label: "Rulers", key: "Shift+KeyR", run: toggleRulers, checked: () => shell.rulers },
      off("slices", "Show slices", undefined, "tools/slice-tool"),
      off("comments", "Comments", "Shift+KeyC", "collaboration/comments"),
      off("outlines", "Outlines", "Mod+KeyY", "canvas/outline-mode"),
      off("cursors", "Multiplayer cursors", "Mod+Alt+Backslash", "canvas/multiplayer-cursors"),
      { id: "memory-usage", label: "Memory usage", run: toggleMemory, checked: () => shell.memory },
      "-",
      { id: "toggle-ui", label: "Show/Hide UI", key: "Mod+Backslash", run: () => (shell.uiHidden = !shell.uiHidden) },
      "-",
      { id: "zoom-in", label: "Zoom in", shows: glyphs("Mod+Equal"), run: () => zoomBy(2) },
      { id: "zoom-out", label: "Zoom out", shows: glyphs("Mod+Minus"), run: () => zoomBy(0.5) },
      { id: "zoom-100", label: "Zoom to 100%", shows: glyphs("Shift+Digit0"), run: () => zoomValue(1) },
      { id: "zoom-fit", label: "Zoom to fit", shows: glyphs("Shift+Digit1"), run: zoomFit },
      { id: "zoom-selection", label: "Zoom to selection", key: "Shift+Digit2", run: zoomSelection, enabled: has },
      "-",
      { id: "previous-page", label: "Previous page", key: "PageUp", run: () => stepPage(-1), enabled: () => pageRows().length > 1 },
      { id: "next-page", label: "Next page", key: "PageDown", run: () => stepPage(1), enabled: () => pageRows().length > 1 },
    ],
  },
  {
    label: "Object",
    items: [
      { id: "group", label: "Group selection", key: "Mod+KeyG", run: () => edits.wrap("group"), enabled: canEdit },
      { id: "ungroup", label: "Ungroup selection", key: "Mod+Shift+KeyG", run: edits.ungroup, enabled: () => canEdit() && types().some((t) => t === "group" || t === "frame" || t === "boolean") },
      { id: "frame", label: "Frame selection", key: "Mod+Alt+KeyG", run: () => edits.wrap("frame"), enabled: canEdit },
      "-",
      off("mask", "Use as mask", "Mod+Ctrl+KeyM", "layers-and-selection/masks"),
      "-",
      { id: "add-auto-layout", label: "Add auto layout", key: "Shift+KeyA", run: edits.addAutoLayout, enabled: canEdit },
      { id: "remove-auto-layout", label: "Remove auto layout", key: "Alt+Shift+KeyA", run: edits.removeAutoLayout, enabled: () => canEdit() && infos().some((i) => !!i.node.layout) },
      "-",
      { id: "create-component", label: "Create component", key: "Mod+Alt+KeyK", run: edits.createComponent, enabled: canEdit },
      { id: "go-to-main", label: "Go to main component", key: "Mod+Alt+Ctrl+KeyK", run: () => void edits.goToMain(), enabled: () => !!shell.inspector?.instanceId },
      { id: "push-to-main", label: "Push changes to main component", run: () => void edits.pushToMain(), enabled: () => canEdit() && edits.canPushToMain() },
      { id: "reset-instance", label: "Reset instance", run: edits.resetOverrides, enabled: () => canEdit() && !!shell.inspector?.hasOverrides },
      { id: "detach", label: "Detach instance", key: "Mod+Alt+KeyB", run: edits.detachInstance, enabled: () => canEdit() && shell.inspector?.kind === "instance" },
      "-",
      { id: "bring-front", label: "Bring to front", key: "Mod+Alt+BracketRight", run: () => edits.reorder(Infinity), enabled: canEdit },
      { id: "bring-forward", label: "Bring forward", key: "Mod+BracketRight", run: () => edits.reorder(1), enabled: canEdit },
      { id: "send-backward", label: "Send backward", key: "Mod+BracketLeft", run: () => edits.reorder(-1), enabled: canEdit },
      { id: "send-back", label: "Send to back", key: "Mod+Alt+BracketLeft", run: () => edits.reorder(-Infinity), enabled: canEdit },
      "-",
      { id: "flip-h", label: "Flip horizontal", key: "Shift+KeyH", run: () => edits.flip("h"), enabled: canEdit },
      { id: "flip-v", label: "Flip vertical", key: "Shift+KeyV", run: () => edits.flip("v"), enabled: canEdit },
      { id: "rotate-180", label: "Rotate 180°", run: () => edits.rotateBy(180), enabled: canEdit },
      { id: "rotate-left", label: "Rotate 90° left", run: () => edits.rotateBy(90), enabled: canEdit },
      { id: "rotate-right", label: "Rotate 90° right", run: () => edits.rotateBy(-90), enabled: canEdit },
      "-",
      off("flatten", "Flatten selection", "Mod+KeyE", "layers-and-selection/flatten"),
      off("outline-stroke", "Outline stroke", "Mod+Alt+KeyO", "layers-and-selection/outline-stroke"),
      off("rasterize", "Rasterize selection", undefined, "layers-and-selection/rasterize-selection"),
      "-",
      { id: "toggle-visible", label: "Show/Hide selection", key: "Mod+Shift+KeyH", run: edits.toggleVisible, enabled: canEdit },
      { id: "toggle-locked", label: "Lock/Unlock selection", key: "Mod+Shift+KeyL", run: edits.toggleLocked, enabled: canEdit },
      "-",
      { id: "remove-fill", label: "Remove fill", key: "Alt+Slash", run: () => edits.removePaints("fills"), enabled: () => canEdit() && infos().some((i) => ((i.node.fills as unknown[] | undefined) ?? []).length > 0) },
      { id: "remove-stroke", label: "Remove stroke", key: "Shift+Slash", run: () => edits.removePaints("strokes"), enabled: () => canEdit() && infos().some((i) => ((i.node.strokes as unknown[] | undefined) ?? []).length > 0) },
      { id: "swap-fill-stroke", label: "Swap fill and stroke", key: "Shift+KeyX", run: edits.swapFillStroke, enabled: canEdit },
    ],
  },
  {
    label: "Text",
    items: [
      { id: "bold", label: "Bold", key: "Mod+KeyB", run: edits.toggleBold, enabled: texts },
      { id: "italic", label: "Italic", key: "Mod+KeyI", run: edits.toggleItalic, enabled: texts },
      { id: "underline", label: "Underline", key: "Mod+KeyU", run: () => edits.toggleDecoration("underline"), enabled: texts, checked: () => texts() && shell.inspector?.typography?.decoration === "underline" },
      { id: "strikethrough", label: "Strikethrough", key: "Mod+Shift+KeyX", run: () => edits.toggleDecoration("strikethrough"), enabled: texts, checked: () => texts() && shell.inspector?.typography?.decoration === "strikethrough" },
      off("link", "Create link", undefined, "text/links"),
      off("bulleted-list", "Bulleted list", "Mod+Shift+Digit8", "text/lists"),
      off("numbered-list", "Numbered list", "Mod+Shift+Digit7", "text/lists"),
      "-",
      {
        label: "Alignment",
        items: [
          { id: "text-left", label: "Text align left", key: "Mod+Alt+KeyL", run: () => edits.setTextAlign("left"), enabled: texts, checked: () => texts() && shell.inspector?.typography?.align === "left" },
          { id: "text-center", label: "Text align center", key: "Mod+Alt+KeyT", run: () => edits.setTextAlign("center"), enabled: texts, checked: () => texts() && shell.inspector?.typography?.align === "center" },
          { id: "text-right", label: "Text align right", key: "Mod+Alt+KeyR", run: () => edits.setTextAlign("right"), enabled: texts, checked: () => texts() && shell.inspector?.typography?.align === "right" },
          { id: "text-justified", label: "Text align justified", key: "Mod+Alt+KeyJ", run: () => edits.setTextAlign("justify"), enabled: texts, checked: () => texts() && shell.inspector?.typography?.align === "justify" },
        ],
      },
      {
        label: "Adjust",
        items: [
          { id: "font-bigger", label: "Increase font size", key: "Mod+Shift+Period", run: () => edits.adjustFontSize(1), enabled: texts },
          { id: "font-smaller", label: "Decrease font size", key: "Mod+Shift+Comma", run: () => edits.adjustFontSize(-1), enabled: texts },
        ],
      },
      {
        label: "Case",
        items: [
          { id: "case-none", label: "Original case", run: () => edits.setTextStyle({ case: "none" }), enabled: texts, checked: () => texts() && (shell.inspector?.typography?.textCase ?? "none") === "none" },
          { id: "case-upper", label: "Uppercase", run: () => edits.setTextStyle({ case: "upper" }), enabled: texts, checked: () => texts() && shell.inspector?.typography?.textCase === "upper" },
          { id: "case-lower", label: "Lowercase", run: () => edits.setTextStyle({ case: "lower" }), enabled: texts, checked: () => texts() && shell.inspector?.typography?.textCase === "lower" },
          { id: "case-title", label: "Title case", run: () => edits.setTextStyle({ case: "title" }), enabled: texts, checked: () => texts() && shell.inspector?.typography?.textCase === "title" },
        ],
      },
    ],
  },
  {
    label: "Arrange",
    items: [
      { id: "align-left", label: "Align left", key: "Alt+KeyA", run: () => edits.align("left"), enabled: canEdit },
      { id: "align-center", label: "Align horizontal centers", key: "Alt+KeyH", run: () => edits.align("center"), enabled: canEdit },
      { id: "align-right", label: "Align right", key: "Alt+KeyD", run: () => edits.align("right"), enabled: canEdit },
      { id: "align-top", label: "Align top", key: "Alt+KeyW", run: () => edits.align("top"), enabled: canEdit },
      { id: "align-middle", label: "Align vertical centers", key: "Alt+KeyV", run: () => edits.align("middle"), enabled: canEdit },
      { id: "align-bottom", label: "Align bottom", key: "Alt+KeyS", run: () => edits.align("bottom"), enabled: canEdit },
      "-",
      off("distribute-h", "Distribute horizontal spacing", "Alt+Ctrl+KeyH", "layers-and-selection/distribute-horizontal-vertical-spacing"),
      off("distribute-v", "Distribute vertical spacing", "Alt+Ctrl+KeyV", "layers-and-selection/distribute-horizontal-vertical-spacing"),
      off("tidy-up", "Tidy up", "Alt+Ctrl+KeyT", "layers-and-selection/tidy-up"),
      "-",
      off("pack-h", "Pack horizontal", undefined, "layers-and-selection/tidy-up"),
      off("pack-v", "Pack vertical", undefined, "layers-and-selection/tidy-up"),
      "-",
      off("round-pixel", "Round to pixel", undefined, "canvas/snap-to-pixel-grid"),
    ],
  },
  {
    label: "Vector",
    items: [
      off("join", "Join selection", "Mod+KeyJ", "vector-editing/join-points"),
      off("smooth", "Smooth selection", "Mod+Alt+KeyJ", "vector-editing/smooth-reverse-path-direction"),
      "-",
      off("union", "Union selection", undefined, "layers-and-selection/boolean-union"),
      off("subtract", "Subtract selection", undefined, "layers-and-selection/boolean-subtract"),
      off("intersect", "Intersect selection", undefined, "layers-and-selection/boolean-intersect"),
      off("exclude", "Exclude selection", undefined, "layers-and-selection/boolean-exclude"),
    ],
  },
  {
    label: "Plugins",
    items: [off("run-last-plugin", "Run last plugin", "Mod+Alt+KeyP", "plugins-and-widgets/run-last-plugin"), "-", off("manage-plugins", "Manage plugins…", undefined, "plugins-and-widgets/manage-plugins"), off("plugin-dev", "Development", undefined, "plugins-and-widgets/development-plugins")],
  },
  {
    label: "Widgets",
    items: [off("find-widgets", "Find more widgets…", undefined, "plugins-and-widgets/widgets"), off("widget-dev", "Development", undefined, "plugins-and-widgets/development-plugins")],
  },
  {
    label: "Preferences",
    items: [
      off("snap-geometry", "Snap to geometry", undefined, "canvas/snap-to-geometry"),
      off("snap-objects", "Snap to objects", undefined, "canvas/snap-to-objects"),
      off("snap-pixels", "Snap to pixel grid", "Mod+Shift+Quote", "canvas/snap-to-pixel-grid"),
      off("keep-tool", "Keep tool selected after use", undefined, "interface/tool-flyouts"),
      off("highlight-hover", "Highlight layers on hover", undefined, "interface/highlight-layers-on-hover"),
      off("nudge", "Nudge amount…", undefined, "layers-and-selection/nudge"),
      "-",
      { id: "theme-light", label: "Light theme", run: () => setTheme("light"), checked: () => shell.themePref === "light" },
      { id: "theme-dark", label: "Dark theme", run: () => setTheme("dark"), checked: () => shell.themePref === "dark" },
      { id: "theme-system", label: "System theme", run: () => setTheme("system"), checked: () => shell.themePref === "system" },
    ],
  },
];

export const HELP: (Action | "-")[] = [
  { id: "feature-requests", label: "Feature requests", run: () => openRequest() },
  "-",
  off("help-page", "Help page", undefined, "interface/help-and-account"),
  off("shortcuts", "Keyboard shortcuts", "Ctrl+Shift+Slash", "interface/shortcuts-panel"),
  off("release-notes", "Release notes"),
  "-",
  off("account", "Account settings", undefined, "interface/help-and-account"),
  off("about", "PublrDesign, Apache-2.0"),
];

// ------------------------------------------------------------ running them

export const isAction = (e: Entry): e is Action => e !== "-" && "id" in e;
export const isSubmenu = (e: Entry): e is { label: string; items: (Action | "-")[] } => e !== "-" && "items" in e;

/** Whether the item can be chosen now. */
export const usable = (a: Action) => !!a.run && (a.enabled ? a.enabled() : true);

/** An item of a feature not built: greyed, and choosing it opens its request. */
export const requestable = (a: Action) => !a.run && !!a.feature;

export function runAction(a: Action): void {
  if (requestable(a)) return openRequest(a.feature);
  if (!usable(a)) return;
  a.run!();
}

/** Every action of the menus, in menu order (the Actions… search lists from these). */
export const ALL: Action[] = [...MENUS.flatMap((m) => m.items.flatMap((e) => (isSubmenu(e) ? e.items : [e]))), ...HELP].filter((e): e is Action => e !== "-");

/** The actions whose name holds `query` (any case), the ones that apply first. */
export function findActions(query: string): Action[] {
  const q = query.trim().toLowerCase();
  if (!q) return [];
  return ALL.filter((a) => a.label.toLowerCase().includes(q));
}

// ------------------------------------------------------------ keys

/** The key the menu shows for `a` ("" none). */
export function keyOf(a: Action): string {
  if (a.shows) return a.shows;
  const k = Array.isArray(a.key) ? a.key[0] : a.key;
  return k ? glyphs(k) : "";
}

const matches = (key: string, e: KeyboardEvent): boolean => {
  const parts = key.split("+");
  const code = parts.pop();
  const mods = new Set(parts);
  const mod = e.metaKey || (e.ctrlKey && !mods.has("Ctrl"));
  return (
    e.code === code &&
    mod === mods.has("Mod") &&
    e.altKey === mods.has("Alt") &&
    e.shiftKey === mods.has("Shift") &&
    (!mods.has("Ctrl") || e.ctrlKey) &&
    // Ctrl held with Cmd is a key of its own: ⌃⌥⌘K is not ⌥⌘K.
    (mods.has("Ctrl") || !(e.ctrlKey && e.metaKey))
  );
};

const typing = (t: EventTarget | null) => t instanceof HTMLElement && (!!t.closest("input, textarea, select, [role=menu], [role=listbox]") || t.isContentEditable);

const KEYED = ALL.filter((a) => a.key && a.run);

/** A key on the canvas: the action it names runs (when it applies). True when the key
 * was an action's. */
export function actionKey(e: KeyboardEvent): boolean {
  if (route.screen !== "file" || typing(e.target)) return false;
  for (const a of KEYED) {
    const keys = Array.isArray(a.key) ? a.key : [a.key!];
    if (!keys.some((k) => matches(k, e))) continue;
    e.preventDefault();
    runAction(a);
    return true;
  }
  return false;
}
