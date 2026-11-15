// The pages Content mode opens: the block editor's demo homepage (the Hearth & Home site,
// its Home template with the site header and footer) and the block editor's manual test
// fixtures (its Pages template), read with the block editor's own model and blocks so the
// two editors show the same annotated HTML (editor/CONTRACT.md) on the same site CSS.
//
// Imported read-only from ../../../editor (the block editor, to be removed later): the
// codec, the core blocks and patterns, the Hearth site data, the demo templates and theme,
// and the jit watcher that compiles a frame's classes. Listed in publr-design-flow.md.

import { registerCoreBlocks } from "../../../editor/blocks/index";
import { registerCorePatterns } from "../../../editor/blocks/patterns";
import type { ThemeToken } from "../../../editor/canvas/engine";
import { downcast, upcastBlocks } from "../../../editor/model/codec";
import { allPatterns } from "../../../editor/model/patterns";
import { blockTypes } from "../../../editor/model/registry";
import { DEMO_THEME } from "../../../editor/harness/demo-theme";
import { HEARTH_HOME, HEARTH_THEME } from "../../../editor/harness/hearth";
import { registerHomePatterns, stampedDocument } from "../../../editor/harness/home-patterns";
import { demoTemplates } from "../../../editor/harness/templates";

export type Fixture = { key: string; group: string; title: string; html: string };

/** A page as Content mode draws it: the template's markup around the content, the content
 * itself (annotated HTML, the document being edited), the site's styles and theme. */
export type PageSource = {
  key: string;
  title: string;
  /** Where the page is ("Hearth & Home · Home template"). */
  location: string;
  /** The template's name. */
  template: string;
  /** The template drawn around the content, its parts filled; `data-publr-slot="content"`
   * marks where the content goes. Not editable. */
  around: string;
  /** The document: annotated HTML, block roots at the top. */
  content: string;
  /** The `title` slot's text, when the template has one. */
  titleSlot: string;
  styles: string[];
  theme: ThemeToken[];
};

export type DocEntry = { key: string; title: string; group: string };

let ready = false;
let fixtures: Fixture[] = [];

const base = new URL("../../../", import.meta.url).href;
const style = (path: string) => new URL(path, base).href;

/** The jit engine the frames' classes compile with (the same build the chrome uses). */
export const JIT_WASM = new URL("../../../runtime/jit_engine.wasm", import.meta.url).href;

async function prepare(): Promise<void> {
  if (ready) return;
  ready = true;
  registerCoreBlocks();
  registerCorePatterns();
  registerHomePatterns();
  try {
    const mod = (await import(new URL("./generated/fixtures.js", import.meta.url).href)) as { fixtures: Fixture[] };
    fixtures = mod.fixtures;
  } catch {
    fixtures = [];
  }
}

/** Every page there is to open: the homepage first, then the fixtures by group. */
export async function documents(): Promise<DocEntry[]> {
  await prepare();
  return [{ key: "hearth", title: "Homepage", group: "Hearth & Home" }, ...fixtures.map((f) => ({ key: f.key, title: f.title, group: f.group === "blocks" ? "Blocks" : "Features" }))];
}

/** Annotated HTML as a renderer writes it (derived classes regenerated). */
const rendered = (html: string) => downcast(upcastBlocks(html), "data");

/** The template around the content with its parts drawn in. */
function around(kind: "home" | "page", title: () => string): string {
  const host = demoTemplates(title, kind);
  const doc = document.implementation.createHTMLDocument("");
  const holder = doc.createElement("div");
  holder.innerHTML = rendered(host.template().html);
  for (const part of holder.querySelectorAll("[data-publr-template-part]")) {
    const source = host.part(part.getAttribute("data-publr-template-part") ?? "");
    if (source) part.innerHTML = rendered(source.html);
  }
  return holder.innerHTML;
}

const FIXTURE_THEME = [...DEMO_THEME, ...HEARTH_THEME.filter((token) => !DEMO_THEME.some((own) => own.name === token.name))];

/** The page named `key`, or null. */
export async function loadDocument(key: string): Promise<PageSource | null> {
  await prepare();
  if (key === "hearth") {
    return {
      key,
      title: "Homepage",
      location: "Hearth & Home",
      template: "Home",
      around: around("home", () => "Homepage"),
      content: stampedDocument(HEARTH_HOME),
      titleSlot: "",
      styles: [style("preflight.css"), style("editor/harness/hearth.css")],
      theme: HEARTH_THEME,
    };
  }
  const fixture = fixtures.find((f) => f.key === key);
  if (!fixture) return null;
  return {
    key,
    title: fixture.title,
    location: `Manual tests · ${fixture.group === "blocks" ? "Blocks" : "Features"}`,
    template: "Pages",
    around: around("page", () => fixture.title),
    content: downcast(upcastBlocks(fixture.html), "editing"),
    titleSlot: fixture.title,
    styles: [style("preflight.css"), style("editor/harness/hearth.css"), style("editor/harness/site.css")],
    theme: FIXTURE_THEME,
  };
}

export type LibraryItem = { type: string; label: string; icon: string };
export type Shelf = { category: string; label: string; items: LibraryItem[] };
export type PatternItem = { name: string; label: string; description: string; category: string };

/** The block editor's inserter shelves and order (editor/shell/session.ts). */
const CATEGORY_ORDER = ["text", "media", "design", "layout", "widgets"];
const CATEGORY_LABELS: Record<string, string> = { text: "Text", media: "Media", design: "Design", layout: "Layout", widgets: "Widgets" };

/** The blocks an inserter offers, by shelf, and the pattern library. */
export async function library(): Promise<{ shelves: Shelf[]; patterns: PatternItem[] }> {
  await prepare();
  const items = blockTypes()
    .filter((type) => !type.internal && !type.phantom && !type.templateOnly)
    .map((type) => ({ type: type.type, label: type.label, icon: type.icon ?? "components", category: type.category ?? "other" }));
  const categories = [...new Set(items.map((item) => item.category))].sort((a, b) => {
    const ia = CATEGORY_ORDER.indexOf(a);
    const ib = CATEGORY_ORDER.indexOf(b);
    return (ia < 0 ? 99 : ia) - (ib < 0 ? 99 : ib);
  });
  const shelves = categories.map((category) => ({ category, label: CATEGORY_LABELS[category] ?? category, items: items.filter((item) => item.category === category).map(({ type, label, icon }) => ({ type, label, icon })) }));
  const patterns = allPatterns().map((p) => ({ name: p.name, label: p.label, description: p.description ?? "", category: p.category ?? "" }));
  return { shelves, patterns };
}
