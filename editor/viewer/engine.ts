// PublrEngine in WASM: a thin wrapper over the C ABI in engine/src/wasm.zig.
//
// One Engine holds one session (a document, its assets and fonts). Bytes go in through
// buffers the engine allocates; answers come back from its result buffer and are copied
// out before the next call.

/** Font roles, as `pe_add_font` takes them. */
export const FontRole = { face: 0, fallback: 1, variable: 2 } as const;

/** A top-level node of a page: box and painted bounds in page units (x0, y0, x1, y1). */
export type Frame = { id: string; name: string; type: string; box: number[]; bounds: number[] };
export type Page = { id: string; name: string; background: number[] | null; frames: Frame[] };
export type DocInfo = { name: string; pages: Page[] };
export type Hit = { id: string; name: string; type: string; top: string; top_name: string; box: number[] };
export type Stats = { memory: number; live: number; image_bytes: number; images: number; drawn: number; culled: number };
export type Pixels = { width: number; height: number; data: Uint8ClampedArray };

interface Exports {
  memory: WebAssembly.Memory;
  pe_alloc(len: number): number;
  pe_free(ptr: number, len: number): void;
  pe_result_ptr(): number;
  pe_result_len(): number;
  pe_result_read(): void;
  pe_result_width(): number;
  pe_result_height(): number;
  pe_error_ptr(): number;
  pe_error_len(): number;
  pe_session_new(): number;
  pe_load_pubd(s: number, ptr: number, len: number): number;
  pe_load_fig(s: number, ptr: number, len: number): number;
  pe_close(s: number): void;
  pe_pubd_json(s: number): number;
  pe_asset(s: number, hash: number, hashLen: number): number;
  pe_zip_open(ptr: number, len: number): number;
  pe_zip_read(index: number): number;
  pe_zip_close(): void;
  pe_add_asset(s: number, hash: number, hashLen: number, ptr: number, len: number): number;
  pe_add_font(s: number, role: number, ptr: number, len: number): number;
  pe_pages(s: number): number;
  pe_render_tile(s: number, page: number, x: number, y: number, scale: number, w: number, h: number, flags: number): number;
  pe_render_node(s: number, id: number, idLen: number, scale: number): number;
  pe_hit_test(s: number, page: number, x: number, y: number): number;
  pe_stats(s: number): number;
  pe_assets(s: number): number;
  pe_page_file(s: number, page: number): number;
  pe_load_page(s: number, page: number, ptr: number, len: number): number;
  pe_unload_page(s: number, page: number): void;
  pe_lazy_assets(s: number, on: number, budget: number): void;
  pe_decode_elsewhere(s: number, on: number): void;
  pe_child_spans(ptr: number, len: number): number;
  pe_begin_page(s: number, page: number, ptr: number, len: number, count: number): number;
  pe_add_page_child(s: number, page: number, ptr: number, len: number): number;
  pe_end_page(s: number, page: number): number;
  pe_node_page(ptr: number, len: number): number;
  pe_node_blob(ptr: number, len: number): number;
  pe_add_page_child_blob(s: number, page: number, ptr: number, len: number): number;
  pe_cancel_page(s: number): void;
  pe_take_wanted(s: number): number;
  pe_decode_image(ptr: number, len: number, level: number): number;
  pe_add_mipmap(s: number, hash: number, hashLen: number, ptr: number, len: number): number;
  pe_mark_bad(s: number, hash: number, hashLen: number): number;
  pe_missing_tile(s: number, page: number, x: number, y: number, scale: number, w: number, h: number): number;
  pe_missing_node(s: number, id: number, idLen: number, scale: number): number;
  pe_zip_directory(ptr: number, len: number, fileSize: number): number;
  pe_zip_list(ptr: number, len: number, count: number): number;
  pe_import_open(canvas: number, canvasLen: number, meta: number, metaLen: number): number;
  pe_import_wants(ref: number, refLen: number): number;
  pe_import_image(ref: number, refLen: number, ptr: number, len: number): number;
  pe_import_page(page: number): number;
  pe_import_page_json(): number;
  pe_import_document(): number;
  pe_fonts(s: number): number;
  pe_font_info(ptr: number, len: number): number;
  pe_add_font_as(s: number, role: number, ptr: number, len: number, family: number, familyLen: number, style: number, styleLen: number): number;
  pe_gpu_new(): number;
  pe_gpu_forget(sc: number): void;
  pe_gpu_shader(which: number): number;
  pe_gpu_page(sc: number, s: number, page: number, x: number, y: number, scale: number, w: number, h: number): number;
  pe_gpu_node(sc: number, s: number, id: number, idLen: number, scale: number, w: number, h: number): number;
  pe_gpu_texture_level(sc: number, tex: number, level: number): number;
  pe_gpu_motion(sc: number, on: number): void;
  pe_gpu_formula(on: number): void;
  pe_rec_new(): number;
  pe_rec_forget(r: number): void;
  pe_rec_free(r: number): void;
  pe_rec_begin(r: number, s: number, page: number): number;
  pe_rec_step(r: number, s: number, count: number): number;
  pe_memory_live(): number;
  pe_rec_build(r: number, s: number, page: number): number;
  pe_rec_update(r: number, s: number, page: number): number;
  pe_rec_frame(r: number, s: number, x: number, y: number, scale: number, w: number, h: number): number;
  pe_rec_held(r: number, s: number, index: number): number;
  pe_rec_level(r: number, s: number, index: number, level: number): number;
  pe_rec_shader(): number;
  pe_rec_item(r: number, sc: number, s: number, index: number, w: number, h: number, margin: number, maxPx: number): number;
  pe_render_layer(s: number, id: number, idLen: number, part: number, child: number, a: number, b: number, c: number, d: number, e: number, f: number, x0: number, y0: number, w: number, h: number): number;
  pe_edit_apply(s: number, ptr: number, len: number): number;
  pe_edit_begin(s: number): number;
  pe_edit_commit(s: number): number;
  pe_edit_cancel(s: number): number;
  pe_edit_hold(s: number, ptr: number, len: number): number;
  pe_edit_select(s: number, ptr: number, len: number): number;
  pe_undo(s: number): number;
  pe_redo(s: number): number;
  pe_edit_out(s: number): number;
  pe_edit_replay(s: number, ptr: number, len: number): number;
  pe_edit_seed(s: number, n: number): void;
  pe_node_info(s: number, id: number, idLen: number): number;
  pe_component(s: number, id: number, idLen: number): number;
  pe_hit_node(s: number, page: number, x: number, y: number, mode: number): number;
  pe_page_tree(s: number, page: number, known: number, same: number): number;
  pe_node_json(s: number, id: number, idLen: number): number;
  pe_font_faces(s: number): number;
  pe_hit_shape(s: number, page: number, x: number, y: number, tol: number): number;
  pe_save_document(s: number): number;
  pe_save_page(s: number, page: number): number;
  pe_dirty_pages(s: number): number;
  pe_saved(s: number): void;
  pe_canvas_nodes(s: number, ptr: number, len: number): number;
  pe_canvas_children(s: number, id: number, idLen: number): number;
  pe_canvas_drop(s: number, page: number, x: number, y: number, ptr: number, len: number): number;
  pe_canvas_resize(s: number, id: number, idLen: number, w: number, h: number, scale: number): number;
  pe_text_layout(s: number, id: number, idLen: number): number;
  pe_variables(s: number): number;
  pe_variable_value(s: number, id: number, idLen: number, ref: number, refLen: number): number;
  pe_variable_table(s: number, col: number, colLen: number): number;
  pe_node_modes(s: number, id: number, idLen: number): number;
  pe_canvas_subtree(s: number, id: number, idLen: number): number;
}

/** What edits did since the last `editOut` (`Editor.takeOut`). */
export type EditOut = {
  /** Every change applied, in order, with the page it is on (-1: the document). */
  changes: { page: number; change: unknown }[];
  /** Page rects painted before and after: [page, x0, y0, x1, y1]. */
  damage: number[][];
  /** The page list changed (names, frames, pages added or removed). */
  pages: boolean;
  undo: boolean;
  redo: boolean;
  /** Bytes the undo history holds. */
  history: number;
};

/** What undo or redo put back. */
export type Restored = { selection: string[]; page: number };

/** A node as a properties panel reads it (`Editor.nodeInfo`). */
/** A component or component set as `document.json`'s `components` lists it. */
export type ComponentEntry = {
  id: string;
  type: "component" | "component-set";
  name: string;
  /** The id of its page, and the page's index (-1 when the document has no such page). */
  page: string;
  pageIndex: number;
  /** A variant: its component set's id ("" none). */
  set: string;
  properties: { id: string; name: string; type: "boolean" | "text" | "instance-swap" | "variant"; default: unknown; options?: unknown[] }[];
};

export type NodeInfo = {
  node: Record<string, unknown>;
  parent: string;
  index: number | null;
  page: number | null;
  children: number;
  box: number[];
  instance?: { id: string; path: string; overrides: string[] | null; main?: string };
  component?: string;
};

/** What `renderLayer` draws of a node (`Session.LayerPart`). */
export const LayerPart = { whole: 0, shadows: 1, innerShadows: 2, maskRun: 3 } as const;

const decoder = new TextDecoder();
const encoder = new TextEncoder();

export class Engine {
  private x: Exports;
  private session: number;

  /** Instantiates a compiled module and opens a session. */
  static async create(module: WebAssembly.Module): Promise<Engine> {
    let memory: WebAssembly.Memory | null = null;
    const instance = await WebAssembly.instantiate(module, {
      env: {
        pe_panic(ptr: number, len: number) {
          const msg = memory ? decoder.decode(new Uint8Array(memory.buffer, ptr, len)) : "panic";
          throw new Error(`engine panic: ${msg}`);
        },
      },
    });
    const x = instance.exports as unknown as Exports;
    memory = x.memory;
    return new Engine(x);
  }

  constructor(x: Exports) {
    this.x = x;
    this.session = x.pe_session_new();
    if (!this.session) throw new Error("engine: out of memory");
  }

  private bytes(ptr: number, len: number): Uint8Array {
    return new Uint8Array(this.x.memory.buffer, ptr, len);
  }

  private text(ptr: number, len: number): string {
    return decoder.decode(this.bytes(ptr, len));
  }

  /** Runs `fn(ptr, len)` with `data` copied into engine memory, then frees it. */
  private with<T>(data: Uint8Array, fn: (ptr: number, len: number) => T): T {
    const len = data.length;
    const size = Math.max(len, 1);
    const ptr = this.x.pe_alloc(size);
    if (!ptr) throw new Error("engine: out of memory");
    try {
      this.bytes(ptr, len).set(data);
      return fn(ptr, len);
    } finally {
      this.x.pe_free(ptr, size);
    }
  }

  /** Copies `data` into a buffer the engine takes over (`pe_add_font`, `pe_add_asset`). */
  private give(data: Uint8Array): [number, number] {
    const len = data.length;
    const ptr = this.x.pe_alloc(Math.max(len, 1));
    if (!ptr) throw new Error("engine: out of memory");
    this.bytes(ptr, len).set(data);
    return [ptr, len];
  }

  private check(rc: number): number {
    if (rc < 0) throw new Error(this.text(this.x.pe_error_ptr(), this.x.pe_error_len()));
    return rc;
  }

  /** The last answer, copied out (a large one's memory goes back to the engine). */
  private result(): Uint8Array {
    const out = this.bytes(this.x.pe_result_ptr(), this.x.pe_result_len()).slice();
    this.x.pe_result_read();
    return out;
  }

  private resultText(): string {
    const out = this.text(this.x.pe_result_ptr(), this.x.pe_result_len());
    this.x.pe_result_read();
    return out;
  }

  private json<T>(): T {
    return JSON.parse(this.resultText()) as T;
  }

  loadPubd(data: Uint8Array): void {
    this.recDropAll();
    this.with(data, (p, n) => this.check(this.x.pe_load_pubd(this.session, p, n)));
  }

  /** Opens a `.fig`'s bytes (copied into a buffer the engine keeps with the document). */
  loadFig(data: Uint8Array): void {
    this.recDropAll();
    const [p, n] = this.give(data);
    this.check(this.x.pe_load_fig(this.session, p, n));
  }

  /** Closes the document and drops its assets and decoded images (fonts stay). */
  close(): void {
    this.recDropAll();
    this.x.pe_close(this.session);
  }

  /** The open document as Pubd `document.json` bytes; for a `.fig`, the import. */
  pubdJson(): Uint8Array {
    this.check(this.x.pe_pubd_json(this.session));
    return this.result();
  }

  /** An asset's encoded bytes by hash (one `pubdJson` names in its `assets`). */
  asset(hash: string): Uint8Array {
    this.with(encoder.encode(hash), (p, n) => this.check(this.x.pe_asset(this.session, p, n)));
    return this.result();
  }

  /** Opens a zip (a `.pubd` file) for `zipRead`; answers its entry names. */
  zipOpen(data: Uint8Array): string[] {
    const [p, n] = this.give(data);
    this.check(this.x.pe_zip_open(p, n));
    return this.json<string[]>();
  }

  /** Entry `index` of the open zip, inflated. */
  zipRead(index: number): Uint8Array {
    this.check(this.x.pe_zip_read(index));
    return this.result();
  }

  zipClose(): void {
    this.x.pe_zip_close();
  }

  addAsset(hash: string, data: Uint8Array): void {
    this.with(encoder.encode(hash), (hp, hn) => {
      const [p, n] = this.give(data);
      this.check(this.x.pe_add_asset(this.session, hp, hn, p, n));
    });
  }

  /** Adds a font file; false when it did not parse. */
  addFont(role: number, data: Uint8Array): boolean {
    const [p, n] = this.give(data);
    return this.check(this.x.pe_add_font(this.session, role, p, n)) === 1;
  }

  pages(): DocInfo {
    this.check(this.x.pe_pages(this.session));
    return this.json<DocInfo>();
  }

  /** RGBA8 (straight alpha) for `w` x `h` device pixels from page point (x, y) at `scale`. */
  renderTile(page: number, x: number, y: number, scale: number, w: number, h: number, flags = 0): Uint8ClampedArray {
    this.check(this.x.pe_render_tile(this.session, page, x, y, scale, w, h, flags));
    return new Uint8ClampedArray(this.result().buffer);
  }

  /** A node exported the way `pe render` draws it. */
  renderNode(id: string, scale: number): Pixels {
    this.with(encoder.encode(id), (p, n) => this.check(this.x.pe_render_node(this.session, p, n, scale)));
    return { width: this.x.pe_result_width(), height: this.x.pe_result_height(), data: new Uint8ClampedArray(this.result().buffer) };
  }

  /** The node at page point (x, y), or null. */
  hitTest(page: number, x: number, y: number): Hit | null {
    this.check(this.x.pe_hit_test(this.session, page, x, y));
    return this.json<Hit | null>();
  }

  stats(): Stats {
    this.check(this.x.pe_stats(this.session));
    return this.json<Stats>();
  }

  // ------------------------------------------------------------ editing

  /** Applies changes (one or a list; engine/src/edit/change.zig) in the open step, or a
   * step of their own. */
  editApply(changes: unknown): void {
    this.with(encoder.encode(JSON.stringify(changes)), (p, n) => this.check(this.x.pe_edit_apply(this.session, p, n)));
  }

  editBegin(): void {
    this.check(this.x.pe_edit_begin(this.session));
  }

  editCommit(): void {
    this.check(this.x.pe_edit_commit(this.session));
  }

  editCancel(): void {
    this.check(this.x.pe_edit_cancel(this.session));
  }

  /** Holds layers in their auto layouts for the open step (a drag): each keeps its place
   * in the flow while the drag moves it; `[]` lets go. */
  editHold(ids: string[]): void {
    this.with(encoder.encode(JSON.stringify(ids)), (p, n) => this.check(this.x.pe_edit_hold(this.session, p, n)));
  }

  /** The selection now: steps keep it to put back. */
  editSelect(ids: string[]): void {
    this.with(encoder.encode(JSON.stringify(ids)), (p, n) => this.check(this.x.pe_edit_select(this.session, p, n)));
  }

  undo(): Restored | null {
    this.check(this.x.pe_undo(this.session));
    return this.json<Restored | null>();
  }

  redo(): Restored | null {
    this.check(this.x.pe_redo(this.session));
    return this.json<Restored | null>();
  }

  /** What changed since the last call, for the workers, the canvas and saving. */
  editOut(): EditOut {
    this.check(this.x.pe_edit_out(this.session));
    return this.json<EditOut>();
  }

  /** Applies changes another engine made, as they are. */
  editReplay(changes: unknown[]): void {
    this.with(encoder.encode(JSON.stringify(changes)), (p, n) => this.check(this.x.pe_edit_replay(this.session, p, n)));
  }

  /** New node ids take this number (one per editing session). */
  editSeed(n: number): void {
    this.x.pe_edit_seed(this.session, n);
  }

  nodeInfo(id: string): NodeInfo {
    this.with(encoder.encode(id), (p, n) => this.check(this.x.pe_node_info(this.session, p, n)));
    return this.json<NodeInfo>();
  }

  /** Component or component set `id` as the document lists it (read from its node when
   * its page is loaded), or null. */
  component(id: string): ComponentEntry | null {
    this.with(encoder.encode(id), (p, n) => this.check(this.x.pe_component(this.session, p, n)));
    return this.json<ComponentEntry | null>();
  }

  /** What a click at page point (x, y) selects: mode 0 the deepest node, 1 as a click does. */
  hitNode(page: number, x: number, y: number, mode: number): Hit | null {
    this.check(this.x.pe_hit_node(this.session, page, x, y, mode));
    return this.json<Hit | null>();
  }

  /** Node `id` with its whole subtree as Pubd JSON (a copy to paste). */
  nodeJson(id: string): Record<string, unknown> {
    this.with(encoder.encode(id), (p, n) => this.check(this.x.pe_node_json(this.session, p, n)));
    return this.json();
  }

  /** Every face text can be set in (variable fonts at their default instance). */
  fontFaces(): { family: string; style: string; weight: number; italic: boolean }[] {
    this.check(this.x.pe_font_faces(this.session));
    return this.json();
  }

  /** Page `page`'s layer tree, as engine/src/edit/tree.zig writes it (copied out);
   * without its JSON when that hashes to `known` (the one the caller holds), or when the
   * caller knows (`same`) the ids, names and guides are still those. */
  pageTree(page: number, known = 0, same = false): Uint8Array {
    this.check(this.x.pe_page_tree(this.session, page, known >>> 0, same ? 1 : 0));
    return this.result();
  }

  /** The deepest layer at page point (x, y) by its real shape, hidden and locked ones
   * skipped; `tol` how near counts (page units). Its id, or null. */
  hitShape(page: number, x: number, y: number, tol: number): string | null {
    this.check(this.x.pe_hit_shape(this.session, page, x, y, tol));
    return this.json<string | null>();
  }

  /** document.json to save (a document in one file is split into pages now). */
  saveDocument(): Uint8Array {
    this.check(this.x.pe_save_document(this.session));
    return this.result();
  }

  /** Page `page`'s file to save. */
  savePage(page: number): Uint8Array {
    this.check(this.x.pe_save_page(this.session, page));
    return this.result();
  }

  /** The pages with changes not saved. */
  dirtyPages(): number[] {
    this.check(this.x.pe_dirty_pages(this.session));
    return this.json<number[]>();
  }

  saved(): void {
    this.x.pe_saved(this.session);
  }

  // ------------------------------------------------------------ the canvas's tools (edit/canvas.zig)

  /** Nodes with their places on the page (null for an id not found). */
  canvasNodes<T>(ids: string[]): (T | null)[] {
    this.with(encoder.encode(JSON.stringify(ids)), (p, n) => this.check(this.x.pe_canvas_nodes(this.session, p, n)));
    return this.json<(T | null)[]>();
  }

  /** Node (or page) `id`'s children with their places on the page. */
  canvasChildren<T>(id: string): T {
    this.with(encoder.encode(id), (p, n) => this.check(this.x.pe_canvas_children(this.session, p, n)));
    return this.json<T>();
  }

  /** The frame a drag dropping at page point (x, y) puts layers in. */
  canvasDrop(page: number, x: number, y: number, exclude: string[]): { id: string; page: boolean } {
    this.with(encoder.encode(JSON.stringify(exclude)), (p, n) => this.check(this.x.pe_canvas_drop(this.session, page, x, y, p, n)));
    return this.json<{ id: string; page: boolean }>();
  }

  /** The changes that resize node `id` to `w` x `h` inside it (`scale`: the scale tool). */
  canvasResize(id: string, w: number, h: number, scale: boolean): unknown[] {
    this.with(encoder.encode(id), (p, n) => this.check(this.x.pe_canvas_resize(this.session, p, n, w, h, scale ? 1 : 0)));
    return this.json<unknown[]>();
  }

  /** Node `id` with its whole subtree as Pubd JSON. */
  canvasSubtree(id: string): Record<string, unknown> {
    this.with(encoder.encode(id), (p, n) => this.check(this.x.pe_canvas_subtree(this.session, p, n)));
    return this.json<Record<string, unknown>>();
  }

  /** The document's variables and collections (pubd/SPEC.md "Variables"). */
  variables(): { collections: ({ id: string; name: string } & Record<string, unknown>)[]; variables: ({ id: string; name: string; collection: string; type: string } & Record<string, unknown>)[] } {
    this.check(this.x.pe_variables(this.session));
    return this.json();
  }

  /** What variable `ref` is worth at node `id` in the modes it is in ("": the defaults). */
  variableValue(id: string, ref: string): unknown {
    const r = encoder.encode(ref);
    this.with(encoder.encode(id), (p, n) => this.with(r, (rp, rn) => this.check(this.x.pe_variable_value(this.session, p, n, rp, rn))));
    return this.json<{ value: unknown }>().value;
  }

  /** Collection `col`'s variables resolved in each of its modes ("": every variable in
   * the default modes): values by variable id, one per mode. */
  variableTable(col: string): Record<string, unknown[]> {
    this.with(encoder.encode(col), (p, n) => this.check(this.x.pe_variable_table(this.session, p, n)));
    return this.json<Record<string, unknown[]>>();
  }

  /** The mode of every collection at node `id`, and the node that chose it. */
  nodeModes(id: string): { collection: string; mode: string; set?: string }[] {
    this.with(encoder.encode(id), (p, n) => this.check(this.x.pe_node_modes(this.session, p, n)));
    return this.json<{ collection: string; mode: string; set?: string }[]>();
  }

  /** Text node `id` laid out: lines and characters for the caret (edit/text_edit.zig). */
  textLayout<T>(id: string): T {
    this.with(encoder.encode(id), (p, n) => this.check(this.x.pe_text_layout(this.session, p, n)));
    return this.json<T>();
  }

  /** The engine's memory (views over it go stale when it grows: take them fresh). */
  get memory(): WebAssembly.Memory {
    return this.x.memory;
  }

  // ------------------------------------------------------------ the GPU canvas

  private scene = 0;

  private sceneHandle(): number {
    if (!this.scene) {
      this.scene = this.x.pe_gpu_new();
      if (!this.scene) throw new Error("engine: out of memory");
    }
    return this.scene;
  }

  /** Forgets what the frame builder keeps between frames and every page's records
   * builder (the document or its fonts changed). */
  gpuForget(): void {
    this.sceneForget();
    this.recForget();
  }

  /** Forgets what the frame builder keeps between frames (a page's nodes were given back:
   * what it keeps refers to them). */
  sceneForget(): void {
    if (this.scene) this.x.pe_gpu_forget(this.scene);
  }

  /** Bytes the engine holds now (its memory's size never shrinks: this does). */
  live(): number {
    return this.x.pe_memory_live() >>> 0;
  }

  /** Shadows of rectangles and ellipses by formula (true) or by passes. */
  gpuFormula(on: boolean): void {
    this.x.pe_gpu_formula(on ? 1 : 0);
  }

  /** While the view moves, glyph masks and polylines of nearby scales stand in. */
  gpuMotion(on: boolean): void {
    this.x.pe_gpu_motion(this.sceneHandle(), on ? 1 : 0);
  }

  /** New glyph masks a frame may rasterise (past them, text draws as paths and the next
   * frames take the rest; 0: text as paths only). */
  gpuGlyphBudget(n: number): void {
    this.x.pe_gpu_glyph_budget(Math.max(0, Math.min(n, 0xffffffff)));
  }

  /** WGSL source: 0 the primitives, 1 the path atlas, 2 the canvas, 3 the effect passes. */
  gpuShader(which: number): string {
    this.check(this.x.pe_gpu_shader(which));
    return this.resultText();
  }

  /** Builds the GPU frame of a page view; answers its header's address (docs/gpu.md). */
  gpuPage(page: number, x: number, y: number, scale: number, w: number, h: number): number {
    return this.check(this.x.pe_gpu_page(this.sceneHandle(), this.session, page, x, y, scale, w, h));
  }

  /** Builds the GPU frame of a node as an export draws it. */
  gpuNode(id: string, scale: number, w: number, h: number): number {
    return this.with(encoder.encode(id), (p, n) => this.check(this.x.pe_gpu_node(this.sceneHandle(), this.session, p, n, scale, w, h)));
  }

  /** Level `level` of the frame's texture `tex`: its address and size. */
  gpuTextureLevel(tex: number, level: number): { ptr: number; width: number; height: number } {
    const ptr = this.check(this.x.pe_gpu_texture_level(this.sceneHandle(), tex, level));
    return { ptr, width: this.x.pe_result_width(), height: this.x.pe_result_height() };
  }

  // ------------------------------------------------------------ records (docs/gpu.md "Records")

  /** A records builder per page whose records are kept (each keeps its page's lists, text
   * layouts and paths between builds). */
  private recs = new Map<number, number>();

  private recordsHandle(page: number): number {
    let r = this.recs.get(page);
    if (!r) {
      r = this.x.pe_rec_new();
      if (!r) throw new Error("engine: out of memory");
      this.recs.set(page, r);
    }
    return r;
  }

  /** Forgets what every records builder keeps between builds (the document or fonts changed). */
  recForget(): void {
    for (const r of this.recs.values()) this.x.pe_rec_forget(r);
  }

  /** Gives page `page`'s records builder back (the page is no longer kept). */
  recDrop(page: number): void {
    const r = this.recs.get(page);
    if (!r) return;
    this.recs.delete(page);
    this.x.pe_rec_free(r);
  }

  /** Gives every page's records builder back (the document closes or another opens). */
  private recDropAll(): void {
    for (const page of [...this.recs.keys()]) this.recDrop(page);
  }

  /** Whether page `page` has a records builder (its records were written). */
  recHas(page: number): boolean {
    return this.recs.has(page);
  }

  /** Writes page `page`'s records; answers their header's address. */
  recBuild(page: number): number {
    return this.check(this.x.pe_rec_build(this.recordsHandle(page), this.session, page));
  }

  /** Starts writing page `page`'s records a few top-level nodes at a time (`recStep`). */
  recBegin(page: number): void {
    this.check(this.x.pe_rec_begin(this.recordsHandle(page), this.session, page));
  }

  /** Writes up to `count` more top-level nodes of page `page`'s records: 0 while some are
   * left, else the address of their header (the page is written). */
  recStep(page: number, count: number): number {
    const r = this.check(this.x.pe_rec_step(this.recordsHandle(page), this.session, count));
    return r === 1 ? 0 : r;
  }

  /** Brings page `page`'s records up to date after edits; answers their header's address
   * (its `full`: 1 written whole, 0 added at the ends, 2 nothing changed, 3 written
   * whole but the paths). */
  recUpdate(page: number): number {
    return this.check(this.x.pe_rec_update(this.recordsHandle(page), this.session, page));
  }

  /** A frame of page `page`'s records: its cameras and the top-level nodes in view;
   * answers the frame header's address. */
  recFrame(page: number, x: number, y: number, scale: number, w: number, h: number): number {
    return this.check(this.x.pe_rec_frame(this.recordsHandle(page), this.session, x, y, scale, w, h));
  }

  /** What image `index` of page `page`'s records holds now (null: nothing yet). */
  recHeld(page: number, index: number): { first: number; levels: number; width: number; height: number } | null {
    const at = this.x.pe_rec_held(this.recordsHandle(page), this.session, index);
    if (at < 0) return null;
    const v = new Uint32Array(this.x.memory.buffer, at, 4);
    return { first: v[0], levels: v[1], width: v[2], height: v[3] };
  }

  /** Level `level` of image `index` of page `page`'s records as held: its address and size. */
  recLevel(page: number, index: number, level: number): { ptr: number; width: number; height: number } {
    const ptr = this.check(this.x.pe_rec_level(this.recordsHandle(page), this.session, index, level));
    return { ptr, width: this.x.pe_result_width(), height: this.x.pe_result_height() };
  }

  /** Item `index` of page `page`'s records drawn by the frame builder at the last frame's
   * camera: the rect it covers (top space), its matrix, the scene's header and whether the
   * rect is cut to the view. */
  recItem(page: number, index: number, w: number, h: number, margin: number, maxPx: number): { rect: number[]; ctm: number[]; scene: number; cut: boolean } {
    this.x.pe_gpu_glyph_budget(0xffffffff);
    this.x.pe_gpu_motion(this.sceneHandle(), 0);
    const at = this.check(this.x.pe_rec_item(this.recordsHandle(page), this.sceneHandle(), this.session, index, w, h, margin, maxPx));
    const i = new Int32Array(this.x.memory.buffer, at, 12);
    const f = new Float32Array(this.x.memory.buffer, at, 12);
    return { rect: [i[0], i[1], i[2], i[3]], ctm: Array.from(f.subarray(4, 10)), scene: i[10] >>> 0, cut: i[11] !== 0 };
  }

  /** The id of item `index`'s node in page `page`'s records (checks). */
  recItemNode(page: number, index: number): string {
    this.check(this.x.pe_rec_item_node(this.recordsHandle(page), index));
    return this.resultText();
  }

  /** The records' WGSL. */
  recShader(): string {
    this.check(this.x.pe_rec_shader());
    return this.resultText();
  }

  /** Part of a node drawn on the CPU under matrix `m` into the device rect: premultiplied RGBA8. */
  renderLayer(id: string, part: number, child: number, m: number[], x0: number, y0: number, w: number, h: number): Uint8Array {
    this.with(encoder.encode(id), (p, n) => this.check(this.x.pe_render_layer(this.session, p, n, part, child, m[0], m[1], m[2], m[3], m[4], m[5], x0, y0, w, h)));
    return this.result();
  }

  /** A string in engine memory. */
  string(ptr: number, len: number): string {
    return this.text(ptr, len);
  }

  // ------------------------------------------------------------ pages and assets on demand

  /** The hashes of the open document's assets. */
  assets(): string[] {
    this.check(this.x.pe_assets(this.session));
    return this.json<string[]>();
  }

  /** Page `page`'s file in a document kept page by page ("" when the page is in the
   * document), whether its nodes are loaded, and then the changes they have had. */
  pageFile(page: number): { src: string; loaded: boolean; edits: number } {
    this.check(this.x.pe_page_file(this.session, page));
    return this.json<{ src: string; loaded: boolean; edits: number }>();
  }

  loadPage(page: number, data: Uint8Array): void {
    this.with(data, (p, n) => this.check(this.x.pe_load_page(this.session, page, p, n)));
  }

  /** Where a page file's top-level nodes are: the `children` array's `[` and end, then
   * each node's start and end (empty: no `children` array). */
  childSpans(data: Uint8Array): number[] {
    this.with(data, (p, n) => this.check(this.x.pe_child_spans(p, n)));
    return this.json<number[]>();
  }

  /** Starts reading page `page` in pieces (no call takes long): its file less its
   * top-level nodes, and how many there are. Not loaded until `endPage`. */
  beginPage(page: number, head: Uint8Array, count: number): void {
    this.with(head, (p, n) => this.check(this.x.pe_begin_page(this.session, page, p, n, count)));
  }

  /** The next top-level node of the page being read in pieces. */
  addPageChild(page: number, data: Uint8Array): void {
    this.with(data, (p, n) => this.check(this.x.pe_add_page_child(this.session, page, p, n)));
  }

  /** A top-level node's JSON read here, as bytes another engine of this build takes
   * (`addPageChildBlob`): render workers read a big page's nodes for the engine that
   * draws. */
  nodeBlob(json: Uint8Array): Uint8Array {
    this.with(json, (p, n) => this.check(this.x.pe_node_blob(p, n)));
    return this.result();
  }

  /** The page whose top-level nodes `nodeBlob` reads next: its file less those nodes
   * (its instances are written against the copies it holds). */
  nodePage(head: Uint8Array): void {
    this.with(head, (p, n) => this.check(this.x.pe_node_page(p, n)));
  }

  /** The next top-level node of the page being read in pieces, read elsewhere
   * (`nodeBlob`). */
  addPageChildBlob(page: number, blob: Uint8Array): void {
    this.with(blob, (p, n) => this.check(this.x.pe_add_page_child_blob(this.session, page, p, n)));
  }

  /** The page read in pieces goes in place. */
  endPage(page: number): void {
    this.check(this.x.pe_end_page(this.session, page));
  }

  cancelPage(): void {
    this.x.pe_cancel_page(this.session);
  }

  /** Gives page `page`'s nodes back (its records builder first: it points into them). */
  unloadPage(page: number): void {
    this.recDrop(page);
    this.x.pe_unload_page(this.session, page);
  }

  /** Drop asset bytes once decoded (they are handed over again when `missing…` names
   * them); `budget` bytes of decoded images at most (0: the engine's default). */
  lazyAssets(on: boolean, budget = 0): void {
    this.x.pe_lazy_assets(this.session, on ? 1 : 0, budget);
  }

  /** Images are decoded elsewhere (`decodeImage` in a worker) and handed over decoded
   * (`addMipmap`): a render never decodes, it draws what is held and notes what it
   * wanted finer (`takeWanted`). */
  decodeElsewhere(on: boolean): void {
    this.x.pe_decode_elsewhere(this.session, on ? 1 : 0);
  }

  /** What the last render (frame, tile or `missing…` walk) wanted decoded: [hash, mip level]. */
  takeWanted(): [string, number][] {
    this.check(this.x.pe_take_wanted(this.session));
    return this.json<[string, number][]>();
  }

  /** An image file decoded into its mip chain from `level` down, packed for `addMipmap`
   * (copied out). Throws when the bytes do not decode. */
  decodeImage(data: Uint8Array, level: number): Uint8Array {
    this.with(data, (p, n) => this.check(this.x.pe_decode_image(p, n, level)));
    return this.result();
  }

  /** Keeps an image another engine decoded (`decodeImage`'s bytes). */
  addMipmap(hash: string, packed: Uint8Array): void {
    this.with(encoder.encode(hash), (hp, hn) => this.with(packed, (p, n) => this.check(this.x.pe_add_mipmap(this.session, hp, hn, p, n))));
  }

  /** An asset that could not be decoded: never wanted again. */
  markBad(hash: string): void {
    this.with(encoder.encode(hash), (p, n) => this.check(this.x.pe_mark_bad(this.session, p, n)));
  }

  /** The assets a `renderTile` with these arguments needs and the engine lacks. */
  missingTile(page: number, x: number, y: number, scale: number, w: number, h: number): string[] {
    this.check(this.x.pe_missing_tile(this.session, page, x, y, scale, w, h));
    return this.json<string[]>();
  }

  /** The assets a `renderNode(id, scale)` needs and the engine lacks. */
  missingNode(id: string, scale: number): string[] {
    this.with(encoder.encode(id), (p, n) => this.check(this.x.pe_missing_node(this.session, p, n, scale)));
    return this.json<string[]>();
  }

  // ------------------------------------------------------------ fonts

  /** The fonts the open document asks for, by family, and which are missing. */
  fonts(): DocFont[] {
    this.check(this.x.pe_fonts(this.session));
    return this.json<DocFont[]>();
  }

  /** Adds a font file under a family (and style) the host names, for a font whose own
   * names are missing or hidden; false when it did not parse. */
  addFontAs(role: number, data: Uint8Array, family: string, style?: string): boolean {
    return this.with(encoder.encode(family), (fp, fn) =>
      this.with(encoder.encode(style ?? ""), (sp, sn) => {
        const [p, n] = this.give(data);
        return this.check(this.x.pe_add_font_as(this.session, role, p, n, fp, fn, sp, style ? sn : 0)) === 1;
      }),
    );
  }

  /** Adds a font, under the names given when there are any. */
  addFontNamed(role: number, data: Uint8Array, family?: string, style?: string): boolean {
    return family ? this.addFontAs(role, data, family, style) : this.addFont(role, data);
  }

  /** What font file `data` holds (TTF, OTF, TTC, WOFF, WOFF2); throws when it is none. */
  fontInfo(data: Uint8Array): FontInfo {
    this.with(data, (p, n) => this.check(this.x.pe_font_info(p, n)));
    return this.json<FontInfo>();
  }

  // ------------------------------------------------------------ importing a .fig in pieces

  /** Where a zip's central directory is, from its last `tail` bytes. */
  zipDirectory(tail: Uint8Array, fileSize: number): { offset: number; size: number; count: number; tail: number } {
    this.with(tail, (p, n) => this.check(this.x.pe_zip_directory(p, n, fileSize)));
    return this.json<{ offset: number; size: number; count: number; tail: number }>();
  }

  /** The entries a central directory lists. */
  zipList(cd: Uint8Array, count: number): ZipItem[] {
    this.with(cd, (p, n) => this.check(this.x.pe_zip_list(p, n, count)));
    return this.json<ZipItem[]>();
  }

  /** Starts importing a `.fig` from its canvas and meta.json bytes. */
  importOpen(canvas: Uint8Array, meta: Uint8Array | null): { pages: number; name: string } {
    this.with(canvas, (cp, cn) =>
      this.with(meta ?? new Uint8Array(0), (mp, mn) => this.check(this.x.pe_import_open(cp, cn, mp, meta ? mn : 0))),
    );
    return this.json<{ pages: number; name: string }>();
  }

  /** Whether the import needs `images/<ref>`. */
  importWants(ref: string): boolean {
    return this.with(encoder.encode(ref), (p, n) => this.check(this.x.pe_import_wants(p, n))) === 1;
  }

  /** Hands over `images/<ref>`'s bytes: the hash its asset file is named by. */
  importImage(ref: string, data: Uint8Array): string {
    this.with(encoder.encode(ref), (rp, rn) => this.with(data, (p, n) => this.check(this.x.pe_import_image(rp, rn, p, n))));
    return this.resultText();
  }

  /** Page `page` built and written: its file's path and JSON bytes. */
  importPage(page: number): { path: string; json: Uint8Array } {
    this.check(this.x.pe_import_page(page));
    const path = this.resultText();
    this.check(this.x.pe_import_page_json());
    return { path, json: this.result() };
  }

  /** document.json, once every page is out; ends the import. */
  importDocument(): Uint8Array {
    this.check(this.x.pe_import_document());
    return this.result();
  }
}

/** A font family the open document asks for, and whether the engine has it. */
export type DocFont = { family: string; styles: string[]; missing: boolean };

/** What a font file holds. */
export type FontInfo = {
  faces: { family: string; style: string; weight: number; italic: boolean }[];
  axes: { tag: string; min: number; default: number; max: number }[];
};

/** A zip entry as its central directory lists it. */
export type ZipItem = { name: string; method: number; csize: number; size: number; local: number };
