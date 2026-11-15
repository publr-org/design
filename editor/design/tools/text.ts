// Editing a text layer on the canvas, as Figma's text editing does: a caret and a
// selection highlight drawn over the text, typing, deleting, moving by character, word
// and line (Shift selects), Cmd+A, copy, cut and paste of plain text, a click or drag in
// the text to place the caret or select, a double-click for a word and a triple-click for
// the paragraph. Typing takes the style of the character before the caret; other runs keep
// theirs. Auto width and auto height text grows as it is typed (the engine lays it out
// again with every change). Esc or a click outside ends it: the whole edit is one undo
// step (Cmd+Z inside undoes the typing step by step). A text whose fonts are missing is
// not edited (Figma asks for the fonts first): a notice says which.
//
// Keys arrive through a hidden textarea (it also places the IME's window at the caret):
// glue, not UI.

import { apply, apply_, clean, editing, engine, geo, inv, mul, translate } from "./geo";
import type { Aff, Geo, Pt } from "./geo";
import { BLUE } from "./marks";
import type { Painter } from "./marks";

type Run = { from: number; to: number; style?: Record<string, unknown>; fills?: unknown };
type Layout = { len: number; lines: [number, number, number, number, number][]; chars: [number, number, number, number][]; missing: string[]; path: boolean };
type State = { text: string; runs: Run[]; anchor: number; focus: number };

/** Characters that end a word. */
const wordChar = (c: string) => /[\p{L}\p{N}_'’]/u.test(c);

export class TextEdit {
  readonly id: string;
  private g: Geo;
  private text = "";
  private runs: Run[] = [];
  private lay: Layout = { len: 0, lines: [], chars: [], missing: [], path: false };
  /** Caret x of each UTF-16 index (0..len) and its line. */
  private xs: number[] = [];
  private lineOf: number[] = [];
  anchor = 0;
  focus = 0;
  /** Up and down keep the x they started from. */
  private goalX: number | null = null;
  private area: HTMLTextAreaElement;
  private undoStack: State[] = [];
  private redoStack: State[] = [];
  private lastKind = "";
  private composing: { from: number; len: number } | null = null;
  private blinkOn = true;
  private blinkTimer = 0;
  private ownsStep: boolean;
  private request: () => void;
  ended = false;

  /** Starts editing text `id`; `ownsStep`: the step is open already (a new text). */
  constructor(id: string, request: () => void, ownsStep: boolean) {
    this.id = id;
    this.request = request;
    this.ownsStep = ownsStep;
    const g = geo(id);
    if (!g || g.type !== "text") throw new Error("not a text layer");
    this.g = g;
    const info = engine()!.nodeInfo(id).node as { text?: string; runs?: Run[] };
    this.text = info.text ?? "";
    this.runs = (info.runs ?? []).map((r) => ({ ...r }));
    if (!ownsStep) editing()!.begin();
    this.relayout();
    this.anchor = 0;
    this.focus = this.text.length;
    this.area = document.createElement("textarea");
    this.area.setAttribute("aria-label", "Text");
    this.area.dataset.pdTextInput = "";
    this.area.autocapitalize = "off";
    this.area.spellcheck = false;
    this.area.style.cssText = "position:fixed;left:0;top:0;width:1px;height:1em;opacity:0;padding:0;border:0;resize:none;overflow:hidden;white-space:pre;z-index:-1";
    document.body.append(this.area);
    this.listen();
    this.syncArea();
    this.area.focus({ preventScroll: true });
    this.blink();
  }

  /** The fonts the text asks for that are not here (editing it is refused). */
  static missing(id: string): string[] {
    try {
      const l = engine()!.textLayout<Layout>(id);
      return [...new Set(l.missing)];
    } catch {
      return [];
    }
  }

  // ------------------------------------------------------------ layout and carets

  private relayout(): void {
    this.g = geo(this.id) ?? this.g;
    this.lay = engine()!.textLayout<Layout>(this.id);
    const n = this.text.length;
    const xs = new Array<number>(n + 1).fill(NaN);
    const ln = new Array<number>(n + 1).fill(-1);
    for (const [i, x, adv, line] of this.lay.chars) {
      if (i > n) continue;
      if (Number.isNaN(xs[i])) {
        xs[i] = x;
        ln[i] = line;
      }
      // The end of a character: the start of the next on the same line.
      const after = i + (this.text.codePointAt(i)! > 0xffff ? 2 : 1);
      if (after <= n && Number.isNaN(xs[after])) {
        xs[after] = x + adv;
        ln[after] = line;
      }
    }
    // A character that starts a line (after a break or a soft wrap): its caret is at the
    // line's start, not after the one before (that one ends the line above).
    for (const [i, x, , line] of this.lay.chars) {
      if (i <= n && ln[i] !== line && i > 0) {
        xs[i] = x;
        ln[i] = line;
      }
    }
    // After a final break: the empty last line.
    const lines = this.lay.lines;
    if (n > 0 && this.isBreakAt(n - 1) && lines.length) {
      xs[n] = lines[lines.length - 1][4];
      ln[n] = lines.length - 1;
    }
    // Characters drawn by one glyph with the one before (ligatures, surrogates): between.
    for (let i = 0; i <= n; i++) {
      if (!Number.isNaN(xs[i])) continue;
      let j = i - 1;
      while (j >= 0 && Number.isNaN(xs[j])) j--;
      let k = i + 1;
      while (k <= n && Number.isNaN(xs[k])) k++;
      const a = j >= 0 ? xs[j] : (lines[0]?.[4] ?? 0);
      const b = k <= n ? xs[k] : a;
      xs[i] = a + ((b - a) * (i - j)) / (k - j);
      ln[i] = j >= 0 ? ln[j] : 0;
    }
    if (n === 0) {
      xs[0] = lines[0]?.[4] ?? this.alignX();
      ln[0] = 0;
    }
    this.xs = xs;
    this.lineOf = ln.map((v) => Math.max(0, v));
  }

  private alignX(): number {
    const w = this.g.size[0];
    return this.g.align === "center" ? w / 2 : this.g.align === "right" ? w : 0;
  }

  private isBreakAt(i: number): boolean {
    const c = this.text[i];
    return c === "\n" || c === " " || c === " ";
  }

  /** The line box (top, height) of line `k`, node space. */
  private lineBox(k: number): [number, number] {
    const l = this.lay.lines[k] ?? this.lay.lines[this.lay.lines.length - 1];
    if (!l) {
      const size = Number((engine()!.nodeInfo(this.id).node as { style?: { size?: number } }).style?.size ?? 12);
      return [0, Math.round(size * 1.21)];
    }
    return [l[0], l[1]];
  }

  /** The UTF-16 index nearest node point (x, y). */
  private indexAt(x: number, y: number): number {
    const lines = this.lay.lines;
    let k = 0;
    for (let i = 0; i < lines.length; i++) if (y >= lines[i][0]) k = i;
    let best = 0;
    let bestD = Infinity;
    for (let i = 0; i <= this.text.length; i++) {
      if (this.lineOf[i] !== k) continue;
      // A break's own caret belongs at the end of its line; the one after it starts the next.
      const d = Math.abs(this.xs[i] - x);
      if (d < bestD) {
        bestD = d;
        best = i;
      }
    }
    return best;
  }

  // ------------------------------------------------------------ changes

  private state(): State {
    return { text: this.text, runs: this.runs.map((r) => ({ ...r })), anchor: this.anchor, focus: this.focus };
  }

  /** Replaces `from..to` with `s` (UTF-16 indices), the caret after it. */
  private replace(from: number, to: number, s: string, kind: string): void {
    if (from === to && !s) return;
    if (kind !== this.lastKind || kind === "other" || /\s/.test(s)) {
      this.undoStack.push(this.state());
      this.redoStack = [];
    }
    this.lastKind = kind;
    this.runs = spliceRuns(this.runs, from, to, s.length);
    this.text = this.text.slice(0, from) + s + this.text.slice(to);
    this.anchor = this.focus = from + s.length;
    this.write();
  }

  /** The text and runs to the engine; auto width text keeps its aligned edge where it was. */
  private write(): void {
    const before = this.g;
    apply_([{ op: "set", node: this.id, props: { text: this.text, runs: this.runs.length ? this.runs : null } }]);
    const after = geo(this.id);
    if (after && before.resize === "width-and-height" && !(after.playout && !after.absolute)) {
      const dw = after.size[0] - before.size[0];
      const shift = before.align === "center" ? -dw / 2 : before.align === "right" ? -dw : 0;
      if (shift) {
        const ctm = mul(before.ctm, translate(shift, 0));
        apply_([{ op: "set", node: this.id, props: { transform: clean(mul(inv(after.pctm), ctm)) } }]);
      }
    }
    this.relayout();
    this.goalX = null;
    this.syncArea();
    this.touch();
  }

  private restoreState(st: State): void {
    this.text = st.text;
    this.runs = st.runs;
    this.anchor = st.anchor;
    this.focus = st.focus;
    this.write();
  }

  undo(): void {
    const st = this.undoStack.pop();
    if (!st) return;
    this.redoStack.push(this.state());
    this.lastKind = "";
    this.restoreState(st);
  }

  redo(): void {
    const st = this.redoStack.pop();
    if (!st) return;
    this.undoStack.push(this.state());
    this.lastKind = "";
    this.restoreState(st);
  }

  private selected(): [number, number] {
    return [Math.min(this.anchor, this.focus), Math.max(this.anchor, this.focus)];
  }

  insert(s: string, kind = "type"): void {
    const [a, b] = this.selected();
    this.replace(a, b, s, kind);
  }

  private setCaret(i: number, extend: boolean): void {
    this.focus = Math.max(0, Math.min(this.text.length, i));
    if (!extend) this.anchor = this.focus;
    this.lastKind = "";
    this.syncArea();
    this.touch();
  }

  // ------------------------------------------------------------ moving the caret

  private prevChar(i: number): number {
    if (i <= 0) return 0;
    const c = this.text.charCodeAt(i - 1);
    return c >= 0xdc00 && c <= 0xdfff && i >= 2 ? i - 2 : i - 1;
  }

  private nextChar(i: number): number {
    if (i >= this.text.length) return this.text.length;
    const c = this.text.charCodeAt(i);
    return c >= 0xd800 && c <= 0xdbff ? i + 2 : i + 1;
  }

  private prevWord(i: number): number {
    while (i > 0 && !wordChar(this.text[i - 1])) i--;
    while (i > 0 && wordChar(this.text[i - 1])) i--;
    return i;
  }

  private nextWord(i: number): number {
    const n = this.text.length;
    while (i < n && !wordChar(this.text[i])) i++;
    while (i < n && wordChar(this.text[i])) i++;
    return i;
  }

  private lineStart(i: number): number {
    const k = this.lineOf[i];
    while (i > 0 && this.lineOf[i - 1] === k && !this.isBreakAt(i - 1)) i--;
    return i;
  }

  private lineEnd(i: number): number {
    const k = this.lineOf[i];
    const n = this.text.length;
    while (i < n && this.lineOf[i + 1] === k && !this.isBreakAt(i)) i++;
    // A wrapped line ends before the space it broke at.
    return i;
  }

  private vertical(i: number, dir: -1 | 1): number {
    const k = this.lineOf[i] + dir;
    if (k < 0) return 0;
    if (k >= this.lay.lines.length) return this.text.length;
    const x = this.goalX ?? this.xs[i];
    const [top, h] = this.lineBox(k);
    const goal = x;
    const at = this.indexAt(x, top + h / 2);
    this.goalX = goal;
    return at;
  }

  private paragraph(i: number): [number, number] {
    let a = i;
    while (a > 0 && !this.isBreakAt(a - 1)) a--;
    let b = i;
    while (b < this.text.length && !this.isBreakAt(b)) b++;
    return [a, b];
  }

  // ------------------------------------------------------------ input

  private listen(): void {
    const a = this.area;
    a.addEventListener("keydown", (e) => this.key(e));
    a.addEventListener("compositionstart", () => {
      const [from, to] = this.selected();
      if (to > from) this.replace(from, to, "", "other");
      this.composing = { from: this.focus, len: 0 };
    });
    a.addEventListener("compositionupdate", (e) => {
      const c = this.composing;
      if (!c) return;
      this.replace(c.from, c.from + c.len, e.data ?? "", "compose");
      c.len = (e.data ?? "").length;
    });
    a.addEventListener("compositionend", (e) => {
      const c = this.composing;
      this.composing = null;
      if (c) this.replace(c.from, c.from + c.len, e.data ?? "", "type");
      this.syncArea();
    });
    a.addEventListener("input", (e) => {
      const ie = e as InputEvent;
      if (ie.isComposing || this.composing) return;
      const value = a.value;
      const kind = ie.inputType === "insertFromPaste" ? "other" : ie.inputType === "deleteByCut" ? "other" : "type";
      // The textarea held the selection: what is there now replaces it.
      this.insert(value.replace(/\r\n?/g, "\n"), kind);
    });
    a.addEventListener("blur", () => {
      // Focus left for another window or a panel: the edit ends there.
      setTimeout(() => {
        if (!this.ended && document.activeElement !== a && document.hasFocus()) this.onBlur();
      }, 0);
    });
  }

  /** Called when focus goes elsewhere (the editor ends the edit). */
  onBlur: () => void = () => {};
  /** Esc: the editor ends the edit and selects the text layer. */
  onExit: () => void = () => {};

  private key(e: KeyboardEvent): void {
    if (this.composing) return;
    const mod = e.metaKey || e.ctrlKey;
    const shift = e.shiftKey;
    const word = e.altKey && !mod;
    const f = this.focus;
    const [s0, s1] = this.selected();
    const handled = () => {
      e.preventDefault();
      e.stopPropagation();
    };
    switch (e.key) {
      case "Escape":
        handled();
        this.onExit();
        return;
      case "ArrowLeft": {
        handled();
        const to = mod ? this.lineStart(f) : word ? this.prevWord(f) : !shift && s0 !== s1 ? s0 : this.prevChar(f);
        this.goalX = null;
        this.setCaret(to, shift);
        return;
      }
      case "ArrowRight": {
        handled();
        const to = mod ? this.lineEnd(f) : word ? this.nextWord(f) : !shift && s0 !== s1 ? s1 : this.nextChar(f);
        this.goalX = null;
        this.setCaret(to, shift);
        return;
      }
      case "ArrowUp":
        handled();
        if (mod) this.setCaret(0, shift);
        else {
          const g = this.goalX;
          const to = this.vertical(f, -1);
          this.setCaret(to, shift);
          this.goalX = g ?? this.goalX;
        }
        return;
      case "ArrowDown":
        handled();
        if (mod) this.setCaret(this.text.length, shift);
        else {
          const g = this.goalX;
          const to = this.vertical(f, 1);
          this.setCaret(to, shift);
          this.goalX = g ?? this.goalX;
        }
        return;
      case "Home":
        handled();
        this.setCaret(this.lineStart(f), shift);
        return;
      case "End":
        handled();
        this.setCaret(this.lineEnd(f), shift);
        return;
      case "Backspace": {
        handled();
        if (s0 !== s1) this.replace(s0, s1, "", "delete");
        else if (mod) this.replace(this.lineStart(f), f, "", "other");
        else if (word) this.replace(this.prevWord(f), f, "", "delete");
        else this.replace(this.prevChar(f), f, "", "delete");
        return;
      }
      case "Delete": {
        handled();
        if (s0 !== s1) this.replace(s0, s1, "", "delete");
        else if (word) this.replace(f, this.nextWord(f), "", "delete");
        else this.replace(f, this.nextChar(f), "", "delete");
        return;
      }
      case "Enter":
        handled();
        // Shift+Enter: a line break inside the paragraph.
        this.insert(shift ? " " : "\n", "other");
        return;
      case "Tab":
        handled();
        this.insert("\t", "type");
        return;
    }
    if (mod && !e.altKey) {
      const k = e.key.toLowerCase();
      if (k === "a") {
        handled();
        this.anchor = 0;
        this.setCaret(this.text.length, true);
        return;
      }
      if (k === "z") {
        handled();
        if (shift) this.redo();
        else this.undo();
        return;
      }
      if (k === "y" && e.ctrlKey) {
        handled();
        this.redo();
        return;
      }
      // Cmd+C, X and V: the textarea holds the selection; its own copy, cut and paste
      // reach `input`. Text styling keys are not ours.
      if (k === "c" || k === "x" || k === "v") return;
      e.preventDefault();
    }
  }

  /** The textarea holds the selected characters, selected (so copy and cut take them,
   * typing and paste replace them), and sits at the caret (the IME's window opens there). */
  private syncArea(): void {
    const [a, b] = this.selected();
    const sel = this.text.slice(a, b);
    if (this.area.value !== sel) this.area.value = sel;
    this.area.setSelectionRange(0, sel.length);
    const p = this.caretPage();
    const s = this.screenOf?.(p) ?? [0, 0];
    this.area.style.left = `${Math.round(s[0])}px`;
    this.area.style.top = `${Math.round(s[1])}px`;
  }

  /** Page point to client pixel (the editor sets it). */
  screenOf: ((p: Pt) => Pt) | null = null;

  private caretPage(): Pt {
    const i = this.focus;
    const [top, h] = this.lineBox(this.lineOf[i] ?? 0);
    return apply(this.g.ctm, this.xs[i] ?? 0, top + h);
  }

  // ------------------------------------------------------------ the pointer

  /** A press at page point (x, y) in the text: the caret there (Shift extends); 2 clicks
   * a word, 3 the paragraph. */
  press(x: number, y: number, shift: boolean, clicks: number): void {
    const [lx, ly] = apply(inv(this.g.ctm), x, y);
    const i = this.indexAt(lx, ly);
    this.goalX = null;
    if (clicks === 2) {
      let a = i;
      let b = i;
      while (a > 0 && wordChar(this.text[a - 1])) a--;
      while (b < this.text.length && wordChar(this.text[b])) b++;
      if (a === b && b < this.text.length) b = this.nextChar(b);
      this.anchor = a;
      this.setCaret(b, true);
    } else if (clicks >= 3) {
      const [a, b] = this.paragraph(i);
      this.anchor = a;
      this.setCaret(b, true);
    } else this.setCaret(i, shift);
    this.area.focus({ preventScroll: true });
  }

  /** A drag from a press: the selection follows. */
  drag(x: number, y: number): void {
    const [lx, ly] = apply(inv(this.g.ctm), x, y);
    this.setCaret(this.indexAt(lx, ly), true);
  }

  /** Whether page point (x, y) is in the text's box (a little around it). */
  contains(x: number, y: number, slop: number): boolean {
    const [lx, ly] = apply(inv(this.g.ctm), x, y);
    const [w, h] = this.g.size;
    return lx >= -slop && ly >= -slop && lx <= w + slop && ly <= h + slop;
  }

  // ------------------------------------------------------------ drawing

  private touch(): void {
    this.blinkOn = true;
    this.blink();
    this.request();
  }

  private blink(): void {
    clearTimeout(this.blinkTimer);
    this.blinkTimer = window.setTimeout(() => {
      this.blinkOn = !this.blinkOn;
      this.request();
      if (!this.ended) this.blink();
    }, 530);
  }

  /** The text's box, the selection highlight and the caret. */
  draw(p: Painter): void {
    const ctx = p.ctx;
    const m = this.g.ctm;
    const [s0, s1] = this.selected();
    const quad = (x0: number, y0: number, x1: number, y1: number): Pt[] => [apply(m, x0, y0), apply(m, x1, y0), apply(m, x1, y1), apply(m, x0, y1)].map((q) => p.screen(q[0], q[1]));
    const fill = (pts: Pt[], color: string) => {
      ctx.beginPath();
      pts.forEach((q, k) => (k ? ctx.lineTo(q[0], q[1]) : ctx.moveTo(q[0], q[1])));
      ctx.closePath();
      ctx.fillStyle = color;
      ctx.fill();
    };
    // The box.
    const box = quad(0, 0, this.g.size[0], this.g.size[1]);
    ctx.beginPath();
    box.forEach((q, k) => (k ? ctx.lineTo(Math.round(q[0]) + 0.5, Math.round(q[1]) + 0.5) : ctx.moveTo(Math.round(q[0]) + 0.5, Math.round(q[1]) + 0.5)));
    ctx.closePath();
    ctx.strokeStyle = BLUE;
    ctx.lineWidth = 1;
    ctx.stroke();
    if (s1 > s0) {
      // One highlight per line the selection crosses.
      // Each selected character's own box, so the first character after a wrap and the
      // space before it count on their own lines.
      const lines = new Map<number, [number, number]>();
      const span = (k: number, a: number, b: number) => {
        const r = lines.get(k);
        lines.set(k, r ? [Math.min(r[0], a), Math.max(r[1], b)] : [a, b]);
      };
      for (const [i, x, adv, k] of this.lay.chars) if (i >= s0 && i < s1) span(k, x, x + adv);
      // A selected break has no glyph: a sliver at the end of its line.
      for (let i = s0; i < s1; i++) if (this.isBreakAt(i)) span(this.lineOf[i], this.xs[i], this.xs[i]);
      for (const [k, [x0, x1]] of lines) {
        const [top, h] = this.lineBox(k);
        fill(quad(x0, top, Math.max(x1, x0 + 2 / p.zoom()), top + h), "rgba(13,153,255,0.3)");
      }
    }
    if (s0 === s1 && this.blinkOn) {
      const i = this.focus;
      const [top, h] = this.lineBox(this.lineOf[i] ?? 0);
      const x = this.xs[i] ?? 0;
      const a = p.screen(...apply(m, x, top));
      const b = p.screen(...apply(m, x, top + h));
      ctx.beginPath();
      ctx.moveTo(Math.round(a[0]) + 0.5, a[1]);
      ctx.lineTo(Math.round(b[0]) + 0.5, b[1]);
      ctx.strokeStyle = "#000000";
      ctx.lineWidth = Math.max(1, Math.min(2, p.zoom() * 0.75));
      ctx.stroke();
    }
  }

  // ------------------------------------------------------------ ending

  /** Ends the edit as one step; an empty text is removed. */
  end(): void {
    if (this.ended) return;
    this.ended = true;
    clearTimeout(this.blinkTimer);
    this.area.remove();
    const ed = editing();
    if (!ed) return;
    if (!this.text.length) apply_([{ op: "delete", node: this.id }]);
    ed.commit();
    void this.ownsStep;
  }

  /** The text is empty (it goes when the edit ends). */
  get empty(): boolean {
    return !this.text.length;
  }
}

/** Runs after `from..to` is replaced by `len` characters: the new ones take the style of
 * the run holding the character before them (at the start: the one after), the rest
 * keep theirs; runs left empty go. */
export function spliceRuns(runs: Run[], from: number, to: number, len: number): Run[] {
  const delta = len - (to - from);
  const holder = from > 0 ? runs.find((r) => r.from <= from - 1 && from - 1 < r.to) : runs.find((r) => r.from <= to && to < r.to);
  const out: Run[] = [];
  for (const r of runs) {
    let a: number;
    let b: number;
    if (r === holder) {
      a = from > 0 ? r.from : 0;
      b = r.to >= to ? r.to + delta : from + len;
      if (from === 0) a = 0;
    } else {
      a = r.from < from ? r.from : r.from >= to ? r.from + delta : from + len;
      b = r.to <= from ? r.to : r.to >= to ? r.to + delta : from + len;
      if (r.from < from && r.to > from && r.to <= to) b = from;
    }
    if (b > a) out.push({ ...r, from: a, to: b });
  }
  return out;
}

export type { Aff };
