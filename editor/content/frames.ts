// Content mode's document adapter: the page drawn in one same-origin frame per breakpoint,
// each a full copy of the page (the template around the content, the site's styles, the
// classes compiled by the jit against the site's theme), laid side by side on the canvas.
// What the tools select and edit are keys stamped on the bound, editable elements of the
// content (the wire contract's block roots and field carriers); every frame carries the
// same keys, so an edit made in one is copied to the others and the selection shows in all.
//
// This is DOM work on the page's own HTML, not chrome: the frames hold content.

import { Watcher, loadEngine } from "../../../editor/canvas/engine";
import { blockType } from "../../../editor/model/registry";
import { getPattern } from "../../../editor/model/patterns";
import type { Device } from "./breakpoints";
import type { PageSource } from "./documents";
import { JIT_WASM } from "./documents";

/** The keys: a block's, a field's (one element may be both: a block that is its own
 * carrier, a heading or a paragraph). */
export const BLOCK_KEY = "data-pd-block";
export const FIELD_KEY = "data-pd-field";
export const keyAttr = (key: string) => (key.startsWith("b") ? BLOCK_KEY : FIELD_KEY);
const FIELD_SEL = "[data-pb-rich],[data-pb-text],[data-pb-image],[data-pb-link]";
/** Gap between breakpoints laid side by side, page units. */
export const GAP = 120;

export type Box = [number, number, number, number];

/** How a field edits, read from the content itself (publr-design-flow.md, "What an element
 * edits as"). */
export type TextKind = "plain" | "multiline" | "rich";
export type Format = "bold" | "italic" | "underline" | "strikethrough" | "link" | "code" | "subscript" | "superscript";

export type FieldInfo = {
  key: string;
  block: string;
  /** "Heading", "Button", "Image". */
  label: string;
  /** The text the field holds (none for an image alone). */
  text: TextKind | null;
  /** Rich text: the formats the content uses. */
  formats: Format[];
  /** Line breaks are newline characters (pre-formatted text), not `<br>`. */
  newlines: boolean;
  /** The text has line breaks: Enter makes one; without, Enter ends the edit. */
  breaks: boolean;
  image: boolean;
  link: boolean;
};

export type BlockInfo = { key: string; label: string; fields: string[] };

const FORMAT_TAGS: Record<string, Format> = {
  strong: "bold",
  b: "bold",
  em: "italic",
  i: "italic",
  u: "underline",
  s: "strikethrough",
  del: "strikethrough",
  strike: "strikethrough",
  a: "link",
  code: "code",
  sub: "subscript",
  sup: "superscript",
};

export class Frame {
  /** The breakpoint it shows; a fixed one becomes free when its width is dragged. */
  device: Device;
  readonly iframe: HTMLIFrameElement;
  doc!: Document;
  root!: HTMLElement;
  x = 0;
  y = 0;
  w: number;
  h = 800;
  private watcher: Watcher | null = null;
  private resize: ResizeObserver | null = null;
  ready: Promise<void>;

  constructor(world: HTMLElement, device: Device, page: PageSource, content: string, onLayout: () => void) {
    this.device = device;
    this.w = device.width;
    const iframe = document.createElement("iframe");
    iframe.title = `${device.label} page`;
    iframe.setAttribute("tabindex", "-1");
    iframe.dataset.pdFrame = device.key;
    iframe.style.cssText = `position:absolute;left:0;top:0;width:${device.width}px;height:${this.h}px;border:0;display:block;pointer-events:none;background:#fff;box-shadow:0 0 0 1px rgba(0,0,0,0.08),0 2px 12px rgba(0,0,0,0.08)`;
    world.append(iframe);
    this.iframe = iframe;
    this.ready = this.build(page, content, onLayout);
  }

  private async build(page: PageSource, content: string, onLayout: () => void): Promise<void> {
    const doc = this.iframe.contentDocument!;
    doc.open();
    doc.write(`<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"></head><body></body></html>`);
    doc.close();
    this.doc = doc;
    const loads: Promise<void>[] = [];
    for (const href of page.styles) {
      const link = doc.createElement("link");
      link.rel = "stylesheet";
      link.href = href;
      loads.push(
        new Promise((done) => {
          link.addEventListener("load", () => done());
          link.addEventListener("error", () => done());
        }),
      );
      doc.head.append(link);
    }
    const own = doc.createElement("style");
    // The frame is as tall as its page (the canvas scrolls, never the frame); an empty
    // caption takes no room, as on the published page; editing shows no outline of its own.
    own.textContent = `html,body{overflow:hidden!important;height:auto!important;min-height:0!important}figcaption[data-pb-rich]:empty{display:none}[contenteditable]{outline:none;cursor:text}[data-pd-root]>script{display:none}`;
    doc.head.append(own);
    const holder = doc.createElement("div");
    holder.dataset.pdPage = "";
    holder.innerHTML = page.around;
    const slot = holder.querySelector('[data-publr-slot="content"]');
    const root = doc.createElement(slot?.localName ?? "div");
    if (slot?.getAttribute("class")) root.setAttribute("class", slot.getAttribute("class")!);
    root.dataset.pdRoot = "";
    root.innerHTML = content;
    if (slot) slot.replaceWith(root);
    else holder.append(root);
    for (const title of holder.querySelectorAll('[data-publr-slot="title"]')) {
      for (const child of [...title.childNodes]) if (!(child.nodeType === 1 && (child as Element).localName === "script")) child.remove();
      title.append(doc.createTextNode(page.titleSlot));
    }
    doc.body.append(holder);
    this.root = root;
    stampKeys(root);
    await loadEngine(JIT_WASM);
    this.watcher = new Watcher(doc, page.theme);
    await Promise.race([Promise.all(loads), new Promise((done) => setTimeout(done, 1500))]);
    const view = doc.defaultView!;
    this.resize = new view.ResizeObserver(() => {
      this.measure();
      onLayout();
    });
    this.resize.observe(doc.body);
    // Images change the height as they arrive.
    doc.addEventListener("load", () => onLayout(), true);
    this.measure();
  }

  /** The frame takes its page's height. */
  measure(): void {
    const h = Math.max(200, Math.ceil(this.doc.body.getBoundingClientRect().height));
    if (h !== this.h) {
      this.h = h;
      this.iframe.style.height = `${h}px`;
    }
  }

  /** Free responsive mode: the frame takes any width; its page lays out again. */
  setWidth(w: number): void {
    this.w = w;
    this.iframe.style.width = `${w}px`;
  }

  place(x: number, y: number): void {
    this.x = x;
    this.y = y;
    this.iframe.style.left = `${x}px`;
    this.iframe.style.top = `${y}px`;
  }

  el(key: string): HTMLElement | null {
    return this.root?.querySelector(`[${keyAttr(key)}="${key}"]`) ?? null;
  }

  /** The element's box in page units (the canvas's), or null when it takes no room. */
  box(key: string): Box | null {
    const el = this.el(key);
    if (!el) return null;
    const r = el.getBoundingClientRect();
    if (r.width === 0 && r.height === 0) return null;
    return [this.x + r.left, this.y + r.top, this.x + r.right, this.y + r.bottom];
  }

  contains(px: number, py: number): boolean {
    return px >= this.x && px <= this.x + this.w && py >= this.y && py <= this.y + this.h;
  }

  /** The element at page point (px, py). */
  elementAt(px: number, py: number): Element | null {
    if (!this.contains(px, py) || !this.doc) return null;
    return this.doc.elementFromPoint(px - this.x, py - this.y);
  }

  destroy(): void {
    this.resize?.disconnect();
    this.watcher?.disconnect();
    this.iframe.remove();
  }
}

/** Keys on the content's blocks (`b<i>`) and their fields (`f<i>-<j>`), in document
 * order: every frame drawn from the same content gets the same keys. A block with no
 * field to edit gets none: nothing in it selects. */
export function stampKeys(root: HTMLElement): void {
  let i = 0;
  for (const block of root.children) {
    if (block.localName === "script") continue;
    const fields = [...(block.matches(FIELD_SEL) ? [block] : []), ...block.querySelectorAll(FIELD_SEL)];
    const k = i++;
    if (!fields.length) continue;
    block.setAttribute(BLOCK_KEY, `b${k}`);
    fields.forEach((field, j) => field.setAttribute(FIELD_KEY, `f${k}-${j}`));
  }
}

const titled = (s: string) => s.replace(/(^|-)(\w)/g, (_, dash: string, c: string) => (dash ? " " : "") + c.toUpperCase());

/** What the content's blocks and fields are, read once from the content as loaded. */
export function readInfo(root: HTMLElement): { blocks: Map<string, BlockInfo>; fields: Map<string, FieldInfo> } {
  const blocks = new Map<string, BlockInfo>();
  const fields = new Map<string, FieldInfo>();
  for (const block of root.querySelectorAll<HTMLElement>(`[${BLOCK_KEY}]`)) {
    const key = block.getAttribute(BLOCK_KEY)!;
    const pattern = block.getAttribute("data-pb-pattern");
    const type = block.getAttribute("data-pb-block") ?? "";
    const label = (pattern && getPattern(pattern)?.label) || blockType(type)?.label || titled(type || "Block");
    blocks.set(key, { key, label, fields: [] });
  }
  for (const el of root.querySelectorAll<HTMLElement>(`[${FIELD_KEY}]`)) {
    const key = el.getAttribute(FIELD_KEY)!;
    const blockKey = `b${key.slice(1, key.indexOf("-"))}`;
    const owner = el.closest("[data-pb-block]");
    const type = owner?.getAttribute("data-pb-block") ?? "";
    const image = el.hasAttribute("data-pb-image");
    const hasText = el.hasAttribute("data-pb-rich") || el.hasAttribute("data-pb-text");
    let text: TextKind | null = null;
    const formats = new Set<Format>();
    let newlines = false;
    let breaks = false;
    if (hasText) {
      for (const inner of el.querySelectorAll("*")) {
        const f = FORMAT_TAGS[inner.localName];
        if (f) formats.add(f);
      }
      const pre = /^pre/.test(el.ownerDocument.defaultView!.getComputedStyle(el).whiteSpace);
      newlines = pre && (el.textContent ?? "").includes("\n");
      breaks = el.querySelector("br") !== null || newlines;
      text = formats.size ? "rich" : breaks ? "multiline" : "plain";
    }
    const isCaption = el.localName === "figcaption";
    const label = isCaption ? "Caption" : blockType(type)?.label || titled(type || "Field");
    fields.set(key, { key, block: blockKey, label, text, formats: [...formats], newlines, breaks, image, link: el.hasAttribute("data-pb-link") });
    blocks.get(blockKey)?.fields.push(key);
  }
  return { blocks, fields };
}

/** The content as annotated HTML, without what the editor put on it. */
export function serialize(root: HTMLElement): string {
  const copy = root.cloneNode(true) as HTMLElement;
  for (const el of copy.querySelectorAll(`[${BLOCK_KEY}], [${FIELD_KEY}]`)) {
    el.removeAttribute(BLOCK_KEY);
    el.removeAttribute(FIELD_KEY);
  }
  for (const el of copy.querySelectorAll("[contenteditable]")) el.removeAttribute("contenteditable");
  return copy.innerHTML;
}
