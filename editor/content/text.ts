// Positions in a field's text as character offsets, and back: text nodes count their
// characters, a `<br>` counts as one line break, a block's settings island (a script) is
// not text, so a caret survives the field's markup
// being written again (undo, a copy from another breakpoint). Words and lines for the
// double and triple click.

/** A settings island or a style: in the field, not its text. */
const skipped = (n: Node) => n.nodeType === 1 && ((n as Element).localName === "script" || (n as Element).localName === "style");

/** The field's text as offsets see it (a `<br>` is "\n"). */
export function textOf(field: Element): string {
  let out = "";
  const walk = (node: Node) => {
    if (node.nodeType === 3) out += (node as Text).data;
    else if (node.nodeType === 1 && (node as Element).localName === "br") out += "\n";
    else if (!skipped(node)) for (const child of node.childNodes) walk(child);
  };
  walk(field);
  return out;
}

/** The offset of DOM position (node, offset) in `field`. */
export function offsetOf(field: Element, node: Node, offset: number): number {
  if (node !== field && !field.contains(node)) {
    // Outside: before or after the whole field.
    const pos = field.compareDocumentPosition(node);
    return pos & Node.DOCUMENT_POSITION_PRECEDING ? 0 : textOf(field).length;
  }
  let count = 0;
  let done = false;
  const walk = (n: Node): void => {
    if (done) return;
    if (n === node && n.nodeType === 3) {
      count += offset;
      done = true;
      return;
    }
    if (n === node) {
      // An element position: the children before `offset`.
      for (let i = 0; i < offset && i < n.childNodes.length; i++) walk(n.childNodes[i]);
      done = true;
      return;
    }
    if (n.nodeType === 3) count += (n as Text).data.length;
    else if (n.nodeType === 1 && (n as Element).localName === "br") count += 1;
    else if (!skipped(n)) for (const child of n.childNodes) walk(child);
  };
  walk(field);
  return count;
}

/** The DOM position `offset` characters into `field`. */
export function positionAt(field: Element, offset: number): { node: Node; offset: number } {
  let left = Math.max(0, offset);
  let found: { node: Node; offset: number } | null = null;
  const walk = (n: Node): void => {
    if (found) return;
    if (n.nodeType === 3) {
      const len = (n as Text).data.length;
      if (left <= len) {
        found = { node: n, offset: left };
        return;
      }
      left -= len;
    } else if (n.nodeType === 1 && (n as Element).localName === "br") {
      const parent = n.parentNode!;
      const index = [...parent.childNodes].indexOf(n as ChildNode);
      if (left === 0) {
        found = { node: parent, offset: index };
        return;
      }
      left -= 1;
      if (left === 0 && !n.nextSibling) {
        found = { node: parent, offset: index + 1 };
        return;
      }
    } else if (!skipped(n)) for (const child of n.childNodes) walk(child);
  };
  walk(field);
  return found ?? { node: field, offset: field.childNodes.length };
}

/** Selects [anchor, focus] in `field` (focus may come first: a backwards selection). */
export function selectOffsets(field: Element, anchor: number, focus: number): void {
  const sel = field.ownerDocument.getSelection();
  if (!sel) return;
  const a = positionAt(field, anchor);
  const f = positionAt(field, focus);
  sel.setBaseAndExtent(a.node, a.offset, f.node, f.offset);
}

/** The selection in `field` as [anchor, focus] offsets, or null when it is elsewhere. */
export function selectionOffsets(field: Element): [number, number] | null {
  const sel = field.ownerDocument.getSelection();
  if (!sel || !sel.anchorNode || !sel.focusNode) return null;
  if (!field.contains(sel.anchorNode) && sel.anchorNode !== field) return null;
  return [offsetOf(field, sel.anchorNode, sel.anchorOffset), offsetOf(field, sel.focusNode, sel.focusOffset)];
}

const segmenter = typeof Intl !== "undefined" && "Segmenter" in Intl ? new Intl.Segmenter(undefined, { granularity: "word" }) : null;

/** The word (or run of spaces or punctuation) around `offset`: [start, end). */
export function wordAt(text: string, offset: number): [number, number] {
  if (!text.length) return [0, 0];
  const at = Math.min(offset, text.length - 1);
  if (segmenter) {
    for (const s of segmenter.segment(text)) {
      if (at >= s.index && at < s.index + s.segment.length) return [s.index, s.index + s.segment.length];
    }
  }
  const word = (c: string) => /[\p{L}\p{N}_'’]/u.test(c);
  const kind = word(text[at]);
  let a = at;
  let b = at + 1;
  while (a > 0 && word(text[a - 1]) === kind && text[a - 1] !== "\n") a--;
  while (b < text.length && word(text[b]) === kind && text[b] !== "\n") b++;
  return [a, b];
}

/** The line (between line breaks) around `offset`: [start, end), the break left out. */
export function lineAt(text: string, offset: number): [number, number] {
  let a = Math.min(offset, text.length);
  while (a > 0 && text[a - 1] !== "\n") a--;
  let b = Math.min(offset, text.length);
  while (b < text.length && text[b] !== "\n") b++;
  return [a, b];
}

/** The caret offset in `field` nearest frame-local point (x, y), the point kept inside the
 * field's box (a drag above the field reaches its first line, below its last). */
export function offsetAtPoint(field: Element, x: number, y: number): number {
  const doc = field.ownerDocument;
  const r = field.getBoundingClientRect();
  if (y < r.top) return 0;
  if (y > r.bottom) return textOf(field).length;
  const cx = Math.min(Math.max(x, r.left + 1), r.right - 1);
  const cy = Math.min(Math.max(y, r.top + 1), r.bottom - 1);
  const d = doc as Document & { caretPositionFromPoint?: (x: number, y: number) => { offsetNode: Node; offset: number } | null };
  if (d.caretPositionFromPoint) {
    const p = d.caretPositionFromPoint(cx, cy);
    if (p) return offsetOf(field, p.offsetNode, p.offset);
  }
  const range = doc.caretRangeFromPoint(cx, cy);
  return range ? offsetOf(field, range.startContainer, range.startOffset) : 0;
}
