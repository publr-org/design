// Editing the open document from the viewer. The engine on this thread (the GPU canvas's)
// applies every change and undoes it (engine/src/edit/editor.zig); the render workers
// replay what it did, in order; the canvas redraws (the GPU in the same frame, CPU tiles
// where the change painted); a file of the browser saves itself a moment after each
// step. No UI: tools and panels call this, and so does the console (`window.viewer.edit`).
//
// This is glue, not UI.

import { updateMeta, writePath } from "../home/store";
import type { EditOut, Engine, Hit, NodeInfo, Restored } from "./engine";
import type { Pool } from "./pool";
import type { Stage } from "./stage";

/** What a change notice follows. */
export type ChangeWhy = "edit" | "commit" | "cancel" | "undo" | "redo";

/** How long after a step a file saves itself. */
const SAVE_AFTER_MS = 800;

export class Editing {
  stage: Stage;
  engine: Engine | null = null;
  pool: Pool | null = null;
  /** The file of the browser being edited ("" for the served document until `adopt`
   * gives it one). */
  fileId = "";
  /** A document with no file of its own (the one `pe view` serves) gets one here on its
   * first save: the file's id (null: it stays unsaved). */
  adopt: (() => Promise<string>) | null = null;
  /** The page list changed (names, frames, pages): the chrome shows it again. */
  onPages: () => void = () => {};
  /** Undo or redo went to another page. */
  onPage: (page: number) => void = () => {};
  /** Saving: "saving", "saved", or an error. */
  onSave: (state: string) => void = () => {};
  /** What the last call did. */
  last: EditOut | null = null;
  /** An editor shell's selection (several layers), when it keeps its own: steps record
   * it, and undo and redo put it back through `restoreSelection`. */
  selectionSource: (() => string[]) | null = null;
  restoreSelection: ((ids: string[]) => void) | null = null;
  /** Whether Cmd+Z and Cmd+Shift+Z are this document's now: with two canvases side by
   * side, only the one in focus takes them. */
  keys: () => boolean = () => true;
  private listeners = new Set<(out: EditOut, why: ChangeWhy) => void>();
  /** Milliseconds the last edit took to apply (engine) and to show (the next frame). */
  lastApplyMs = 0;
  lastFrameMs = 0;
  private saveTimer = 0;
  private saving: Promise<void> = Promise.resolve();
  private toWorkers: Promise<unknown> = Promise.resolve();

  constructor(stage: Stage) {
    this.stage = stage;
    this.listen();
  }

  /** Edits `engine`'s document from now on (the workers in `pool` hold the same one). */
  attach(engine: Engine, pool: Pool | null, fileId: string): void {
    this.engine = engine;
    this.pool = pool;
    this.fileId = fileId;
    // New node ids of this session are `<seed>:<n>`.
    engine.editSeed(1_000_000 + Math.floor(Math.random() * 2_000_000_000));
  }

  detach(): void {
    clearTimeout(this.saveTimer);
    this.engine = null;
    this.fileId = "";
    this.adopt = null;
  }

  /** Calls `fn` after every call that changed the document (an edit, a step's commit
   * or cancel, undo, redo), once the canvas has been told; returns the unsubscribe. */
  onChange(fn: (out: EditOut, why: ChangeWhy) => void): () => void {
    this.listeners.add(fn);
    return () => this.listeners.delete(fn);
  }

  private live(): Engine {
    if (!this.engine) throw new Error("no document is open for editing");
    return this.engine;
  }

  // ------------------------------------------------------------ changes and steps

  /** Applies a change or a list of them (one step unless a step is open). */
  edit(changes: unknown): EditOut {
    const e = this.live();
    this.selectionToEngine();
    const t0 = performance.now();
    e.editApply(changes);
    this.lastApplyMs = performance.now() - t0;
    return this.after(t0, "edit");
  }

  /** Starts a step: everything until `commit` undoes as one (a drag). */
  begin(): void {
    this.selectionToEngine();
    this.live().editBegin();
  }

  commit(): EditOut {
    this.selectionToEngine();
    this.live().editCommit();
    return this.after(performance.now(), "commit");
  }

  /** Holds layers in their auto layouts while a drag moves them (`[]` lets go). */
  hold(ids: string[]): EditOut {
    this.live().editHold(ids);
    return this.after(performance.now(), "edit");
  }

  /** Ends the open step by undoing what it did. */
  cancel(): EditOut {
    this.live().editCancel();
    return this.after(performance.now(), "cancel");
  }

  undo(): Restored | null {
    const r = this.live().undo();
    if (r) this.restore(r);
    this.after(performance.now(), "undo");
    return r;
  }

  redo(): Restored | null {
    const r = this.live().redo();
    if (r) this.restore(r);
    this.after(performance.now(), "redo");
    return r;
  }

  /** Node `id` as a properties panel reads it. */
  node(id: string): NodeInfo {
    return this.live().nodeInfo(id);
  }

  /** What a click at page point (x, y) on the page shown selects (`deep`: the deepest). */
  hit(x: number, y: number, deep = false): Hit | null {
    return this.live().hitNode(this.stage.page, x, y, deep ? 0 : 1);
  }

  /** Selects node `id` (null: nothing). */
  select(id: string | null): void {
    if (!id) {
      this.stage.select(null);
      return;
    }
    const info = this.live().nodeInfo(id);
    if (info.page !== null && info.page !== this.stage.page) this.onPage(info.page);
    const n = info.node as { id: string; name?: string; type: string };
    this.stage.select({ id: n.id, name: n.name ?? "", type: n.type, top: n.id, top_name: n.name ?? "", box: info.box });
  }

  private selectionToEngine(): void {
    if (this.selectionSource) {
      this.engine?.editSelect(this.selectionSource());
      return;
    }
    const id = this.stage.selectedId();
    this.engine?.editSelect(id ? [id] : []);
  }

  private restore(r: Restored): void {
    if (r.page >= 0 && r.page !== this.stage.page) this.onPage(r.page);
    if (this.restoreSelection) {
      this.restoreSelection(r.selection);
      return;
    }
    try {
      this.select(r.selection[0] ?? null);
    } catch {
      this.stage.select(null);
    }
  }

  /** What follows every call: the workers replay, the canvas redraws, the file saves. */
  private after(t0: number, why: ChangeWhy): EditOut {
    const out = this.live().editOut();
    this.last = out;
    if (out.changes.length) {
      const pool = this.pool;
      if (pool) {
        const changes = out.changes;
        this.toWorkers = this.toWorkers.then(() => pool.all(() => ({ type: "edit", changes })).catch((err) => console.error("edit replay", err)));
      }
      if (out.pages && this.stage.doc) {
        const doc = this.live().pages();
        this.stage.doc = doc;
        this.onPages();
      }
      this.stage.damage(out.damage);
      // The selection's outline follows its node.
      const sel = this.stage.selectedId();
      if (sel) {
        try {
          const info = this.live().nodeInfo(sel);
          const n = info.node as { id: string; name?: string; type: string };
          this.stage.select({ id: n.id, name: n.name ?? "", type: n.type, top: n.id, top_name: n.name ?? "", box: info.box });
        } catch {
          this.stage.select(null);
        }
      }
      this.scheduleSave();
      requestAnimationFrame(() => {
        // The frame this edit shows in has been drawn when the next one starts.
        requestAnimationFrame(() => (this.lastFrameMs = performance.now() - t0));
      });
    }
    this.stage.requestDraw();
    if (out.changes.length || why === "undo" || why === "redo")
      for (const fn of this.listeners) {
        try {
          fn(out, why);
        } catch (err) {
          console.error("edit listener", err);
        }
      }
    return out;
  }

  /** Waits until the workers have replayed every change so far. */
  settled(): Promise<unknown> {
    return this.toWorkers;
  }

  // ------------------------------------------------------------ saving

  private scheduleSave(): void {
    if (!this.fileId && !this.adopt) return;
    clearTimeout(this.saveTimer);
    this.saveTimer = window.setTimeout(() => void this.save(), SAVE_AFTER_MS);
  }

  /** Writes the pages with changes and document.json to the file of the browser. */
  save(): Promise<void> {
    clearTimeout(this.saveTimer);
    this.saving = this.saving.then(() => this.write()).catch((err) => {
      console.error("save", err);
      this.onSave(`Not saved: ${err instanceof Error ? err.message : String(err)}`);
    });
    return this.saving;
  }

  private async write(): Promise<void> {
    const e = this.engine;
    if (!e) return;
    const dirty = e.dirtyPages();
    if (!dirty.length) return;
    if (!this.fileId && this.adopt) {
      const adopt = this.adopt;
      this.adopt = null;
      const made = await adopt();
      if (this.engine !== e) return;
      this.fileId = made;
    }
    const id = this.fileId;
    if (!id) return;
    this.onSave("saving");
    // A document in one file is split into pages by its first save: every page is
    // written then. document.json goes last: it names the pages' files.
    const pages = e.pages().pages.length;
    const split = pages > 0 && e.pageFile(0).src !== "";
    const doc = e.saveDocument();
    for (let i = 0; i < pages; i++) {
      if (split && !dirty.includes(i)) continue;
      const f = e.pageFile(i);
      if (!f.src || !f.loaded) continue;
      await writePath(id, f.src, e.savePage(i));
    }
    await writePath(id, "document.json", doc);
    e.saved();
    await updateMeta(id, { edited: Date.now(), pages });
    this.onSave("saved");
  }

  // ------------------------------------------------------------ keys

  private listen(): void {
    window.addEventListener("keydown", (e: KeyboardEvent) => {
      if (!this.engine || !this.keys()) return;
      const target = e.target as HTMLElement | null;
      if (target && (target.closest("input, textarea, select, [role=listbox], [role=menu]") || target.isContentEditable)) return;
      const mod = e.metaKey || e.ctrlKey;
      if (!mod) return;
      const redo = (e.code === "KeyZ" && e.shiftKey) || (e.code === "KeyY" && e.ctrlKey && !e.metaKey);
      const undo = e.code === "KeyZ" && !e.shiftKey;
      if (!undo && !redo) return;
      e.preventDefault();
      try {
        if (redo) this.redo();
        else this.undo();
      } catch (err) {
        console.error(redo ? "redo" : "undo", err);
      }
    });
  }
}

/** The console's way in: `window.viewer.edit(change)`, `undo()`, `redo()`, `begin()`,
 * `commit()`, `cancel()`, `node(id)`, `hit(x, y)`, `select(id)`, `save()`,
 * `editTiming()`. */
export function installEditing(editing: Editing): void {
  const w = window as unknown as { viewer?: Record<string, unknown> };
  w.viewer ??= {};
  Object.assign(w.viewer, {
    editing,
    edit: (changes: unknown) => editing.edit(changes),
    undo: () => editing.undo(),
    redo: () => editing.redo(),
    begin: () => editing.begin(),
    commit: () => editing.commit(),
    cancel: () => editing.cancel(),
    node: (id: string) => editing.node(id),
    hit: (x: number, y: number, deep = false) => editing.hit(x, y, deep),
    select: (id: string | null) => editing.select(id),
    save: () => editing.save(),
    /** The last edit: ms in the engine, ms until its frame was drawn, history bytes. */
    editTiming: () => ({ applyMs: editing.lastApplyMs, frameMs: editing.lastFrameMs, history: editing.last?.history ?? 0 }),
  });
}
