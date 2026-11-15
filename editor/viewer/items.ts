// Pictures of the records' items (docs/gpu.md "Records", items): nodes the CPU draws
// through layers of their own (group opacity, effects, masks), drawn by the immediate
// builder at a frame's exact matrix and kept in an atlas. The records' frame composites
// them; while an item has no picture at the frame's matrix, the nearest kept one stands
// in (zooming), and new ones are drawn a few ms a frame, nearest the centre first.
//
// This is glue, not UI: the atlas, the pictures and the table the shader reads.

import type { Engine } from "./engine";
import type { GpuCanvas } from "./gpu";
import { feedOf } from "./feed";

const ATLAS = 4096;
const MAX_LAYERS = 6;
/** Words an item takes in the records (records.zig `Item`), a visible item, a table row. */
export const ITEM_WORDS = 12;
const VISIBLE_WORDS = 12;
export const TABLE_WORDS = 16;
/** An item's picture covers its whole rect up to this many pixels, else the view and
 * this margin around it. */
const WHOLE_PX = 2048 * 2048;
const MARGIN = 256;
/** Items under this many device pixels are not drawn (their stand-ins show). */
const TINY_PX = 16;
/** Items under this many device pixels with a stand-in are drawn exact only once the view
 * rests (`idle`). */
const SMALL_PX = 32 * 32;

const BLIT_WGSL = `
@group(0) @binding(0) var src: texture_2d<f32>;
@group(0) @binding(1) var<uniform> at: vec4i;
@vertex fn vs(@builtin(vertex_index) vi: u32) -> @builtin(position) vec4f {
  let p = vec2f(f32((vi << 1u) & 2u), f32(vi & 2u));
  return vec4f(p * 2.0 - 1.0, 0.0, 1.0);
}
@fragment fn fs(@builtin(position) pos: vec4f) -> @location(0) vec4f {
  return clamp(textureLoad(src, vec2i(floor(pos.xy)) - at.xy, 0), vec4f(0.0), vec4f(1.0));
}`;

/** A picture of an item. */
/** A picture of an item. `lacked`: the images it was drawn without and when (the feed's
 * `installed` count): it is drawn again once one of them comes. */
type Pic = { ctm: number[]; rect: number[]; whole: boolean; layer: number; ax: number; ay: number; w: number; h: number; used: number; scale: number; cam?: number[]; epoch?: number; lacked?: { at: number; hashes: string[] } };

/** Whether `p` is as it would be drawn now: none of the images it lacked has come since. */
function fresh(p: Pic, engine: Engine): boolean {
  const l = p.lacked;
  if (!l) return true;
  const feed = feedOf(engine);
  return !feed || !l.hashes.some((h) => feed.installedSince(h, l.at));
}

/** Item kinds (records.zig `Item`). */
export const ITEM_NODE = 1;
export const ITEM_MASK_RUN = 4;
export const ITEM_BACKDROP = 5;
export const ITEM_INFRAME = 6;

type Shelf = { y: number; h: number; x: number };

const blits = new WeakMap<GPUDevice, { layout: GPUBindGroupLayout; pipeline: GPURenderPipeline }>();

const f32 = new Float32Array(1);
const fr = (v: number) => {
  f32[0] = v;
  return f32[0];
};

export class ItemCache {
  readonly gpu: GpuCanvas;
  /** The page whose records' items these are. */
  readonly page: number;
  readonly device: GPUDevice;
  /** The atlas, made when first used (one layer; more as pictures need them). */
  private atlasTex: GPUTexture | null = null;
  get atlas(): GPUTexture {
    this.atlasTex ??= this.makeAtlas(1);
    return this.atlasTex;
  }
  /** Bumped when the atlas texture is made again (the records' bind group follows). */
  atlasGen = 0;
  private shelves: Shelf[][] = [];
  private layerUsed: number[] = [];
  private pics = new Map<string, Pic[]>();
  private blitPipeline: GPURenderPipeline;
  private blitLayout: GPUBindGroupLayout;
  /** The records' items (copied at each build): kind, top, xf, parent, rect, key. */
  private items = new Uint32Array(0);
  private itemFloats = new Float32Array(0);
  private keys: string[] = [];
  /** The table the shader reads, here, and what of it changed. */
  table = new Uint32Array(0);
  private tableF = new Float32Array(0);
  private chosen: (Pic | null)[] = [];
  dirtyLo = Infinity;
  dirtyHi = -1;
  frameNo = 0;
  /** Bumped when anything a background blur may read changed (a picture, an image): its
   * pictures are taken again. */
  epoch = 0;
  /** Where drawing items went, ms (checks). */
  timing = { build: 0, encode: 0, n: 0 };
  /** Background blurs to take from the target this frame (records draws them in place). */
  backdrops = new Set<number>();
  /** Items in view drawn onto the frame in place this frame (blend modes). */
  inframe = new Set<number>();
  /** Per top-level node: its background blurs' and in-frame items' composite prims and
   * items, in draw order. */
  backdropsOf = new Map<number, number[][]>();
  /** Numbers of the last frame. */
  stats = { visible: 0, exact: 0, standIn: 0, none: 0, drawn: 0, drawMs: 0, bytes: 0, backdrops: 0 };

  constructor(gpu: GpuCanvas, page: number) {
    this.gpu = gpu;
    this.page = page;
    this.device = gpu.device;
    // The blit is the device's, shared by every page's pictures.
    let blit = blits.get(this.device);
    if (!blit) {
      const layout = this.device.createBindGroupLayout({
        entries: [
          { binding: 0, visibility: GPUShaderStage.FRAGMENT, texture: { sampleType: "unfilterable-float" } },
          { binding: 1, visibility: GPUShaderStage.FRAGMENT, buffer: { type: "uniform" } },
        ],
      });
      const module = this.device.createShaderModule({ code: BLIT_WGSL });
      const pipeline = this.device.createRenderPipeline({
        layout: this.device.createPipelineLayout({ bindGroupLayouts: [layout] }),
        vertex: { module, entryPoint: "vs" },
        fragment: { module, entryPoint: "fs", targets: [{ format: "rgba8unorm" }] },
        primitive: { topology: "triangle-list" },
      });
      blits.set(this.device, (blit = { layout, pipeline }));
    }
    this.blitLayout = blit.layout;
    this.blitPipeline = blit.pipeline;
  }

  private makeAtlas(layers: number): GPUTexture {
    const t = this.device.createTexture({
      size: [ATLAS, ATLAS, layers],
      format: "rgba8unorm",
      usage: GPUTextureUsage.RENDER_ATTACHMENT | GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.COPY_SRC | GPUTextureUsage.COPY_DST,
    });
    while (this.shelves.length < layers) {
      this.shelves.push([]);
      this.layerUsed.push(0);
    }
    this.atlasGen++;
    return t;
  }

  /** Gives the atlas up. */
  destroy(): void {
    this.clear();
    if (this.atlasTex) this.gpu.doom(this.atlasTex);
    this.atlasTex = null;
  }

  /** Forgets every picture (the document changed). */
  clear(): void {
    this.pics.clear();
    for (let l = 0; l < this.shelves.length; l++) {
      this.shelves[l] = [];
      this.layerUsed[l] = 0;
    }
  }

  /** The records were written again: their items, and the table for them. */
  setItems(engine: Engine, ptr: number, count: number, partial: boolean): void {
    const was = partial ? this.chosen.length : 0;
    this.items = new Uint32Array(engine.memory.buffer, ptr, count * ITEM_WORDS).slice();
    this.itemFloats = new Float32Array(this.items.buffer);
    if (!partial) this.keys = [];
    for (let i = was; i < count; i++) this.keys.push(`${this.items[i * ITEM_WORDS + 9].toString(36)}.${this.items[i * ITEM_WORDS + 8].toString(36)}`);
    const table = new Uint32Array(Math.max(TABLE_WORDS, count * TABLE_WORDS));
    if (partial) table.set(this.table.subarray(0, Math.min(this.table.length, was * TABLE_WORDS)));
    this.table = table;
    this.tableF = new Float32Array(this.table.buffer);
    if (!partial) this.chosen = [];
    while (this.chosen.length < count) this.chosen.push(null);
    for (let i = was; i < count; i++) this.table[i * TABLE_WORDS + 14] = this.items[i * ITEM_WORDS + 3];
    this.backdropsOf.clear();
    for (let i = 0; i < count; i++) {
      const kind = this.items[i * ITEM_WORDS];
      if ((kind !== ITEM_BACKDROP && kind !== ITEM_INFRAME) || this.items[i * ITEM_WORDS + 1] === 0xffffffff) continue;
      const top = this.items[i * ITEM_WORDS + 1];
      let list = this.backdropsOf.get(top);
      if (!list) this.backdropsOf.set(top, (list = []));
      list.push([this.items[i * ITEM_WORDS + 10], i]);
    }
    for (const list of this.backdropsOf.values()) list.sort((a, b) => a[0] - b[0]);
    this.dirtyLo = Math.min(this.dirtyLo, was);
    this.dirtyHi = Math.max(this.dirtyHi, count - 1);
  }

  get count(): number {
    return this.chosen.length;
  }

  private setRow(i: number, p: Pic | null): void {
    if (this.chosen[i] === p) return;
    this.chosen[i] = p;
    const o = i * TABLE_WORDS;
    const t = this.table;
    if (!p) {
      t[o] = 0;
    } else {
      t[o] = 1;
      t[o + 1] = p.layer;
      t[o + 2] = p.ax;
      t[o + 3] = p.ay;
      t[o + 4] = p.w;
      t[o + 5] = p.h;
      t[o + 6] = p.rect[0] | 0;
      t[o + 7] = p.rect[1] | 0;
      this.tableF.set(p.ctm, o + 8);
    }
    this.dirtyLo = Math.min(this.dirtyLo, i);
    this.dirtyHi = Math.max(this.dirtyHi, i);
  }

  /** The items in view this frame (`visible`: the frame's list, `cams`: its cameras):
   * pictures chosen, new ones drawn within `budgetMs` (only for items with none at all
   * while `moving`). True when every item in view shows its exact picture. */
  update(engine: Engine, visible: Uint32Array, count: number, cams: Float32Array, w: number, h: number, moving: boolean, budgetMs: number, idle = true): boolean {
    this.frameNo++;
    const vf = new Float32Array(visible.buffer, visible.byteOffset, visible.length);
    const vi = new Int32Array(visible.buffer, visible.byteOffset, visible.length);
    const want: { i: number; o: number; pri: number; none: boolean }[] = [];
    this.backdrops.clear();
    this.inframe.clear();
    let waiting = 0;
    const st = this.stats;
    st.visible = count;
    st.exact = st.standIn = st.none = st.backdrops = 0;
    const cx = w / 2;
    const cy = h / 2;
    for (let k = 0; k < count; k++) {
      const o = k * VISIBLE_WORDS;
      const i = visible[o];
      const ctm = [vf[o + 5], vf[o + 6], vf[o + 7], vf[o + 8], vf[o + 9], vf[o + 10]];
      const top = this.items[i * ITEM_WORDS + 1];
      const cox = new Int32Array(cams.buffer, cams.byteOffset, cams.length)[top * 8 + 6];
      const coy = new Int32Array(cams.buffer, cams.byteOffset, cams.length)[top * 8 + 7];
      // What of the item the view shows, top space.
      const need = [Math.max(vi[o + 1], 0) - cox, Math.max(vi[o + 2], 0) - coy, Math.min(vi[o + 3], w) - cox, Math.min(vi[o + 4], h) - coy];
      // The picture shown last frame is still exact (a pan, or no change): nothing to look up.
      const cur = this.chosen[i];
      const kindNow = this.items[i * ITEM_WORDS];
      if (cur && kindNow !== ITEM_BACKDROP && sameCtm(cur.ctm, ctm) && (cur.whole || (cur.rect[0] <= need[0] && cur.rect[1] <= need[1] && cur.rect[2] >= need[2] && cur.rect[3] >= need[3])) && fresh(cur, engine)) {
        cur.used = this.frameNo;
        st.exact++;
        continue;
      }
      // While the zoom moves, what stands in stays (no picture is exact mid-zoom).
      if (moving && cur && kindNow !== ITEM_NODE && kindNow !== ITEM_MASK_RUN) {
        cur.used = this.frameNo;
        st.standIn++;
        continue;
      }
      if (moving && !cur && (kindNow === ITEM_NODE || kindNow === ITEM_MASK_RUN) && this.pics.has(this.keys[i])) {
        st.standIn++;
        continue;
      }
      const list = this.pics.get(this.keys[i]);
      let exact: Pic | null = null;
      let best: Pic | null = null;
      let bestScore = Infinity;
      const scale = Math.hypot(ctm[0], ctm[1]);
      const backdrop = this.items[i * ITEM_WORDS] === ITEM_BACKDROP;
      if (this.items[i * ITEM_WORDS] === ITEM_INFRAME) {
        this.inframe.add(i);
        continue;
      }
      if (list) {
        for (const p of list) {
          const covers = backdrop ? !!p.cam && (p.whole || (p.cam[0] === cox && p.cam[1] === coy)) && p.epoch === this.epoch : p.whole || (p.rect[0] <= need[0] && p.rect[1] <= need[1] && p.rect[2] >= need[2] && p.rect[3] >= need[3]);
          // Drawn without an image that has come since: drawn again.
          if (sameCtm(p.ctm, ctm) && covers && fresh(p, engine)) {
            exact = p;
            break;
          }
          const score = Math.abs(Math.log(p.scale / scale)) + (p.whole ? 0 : 0.5);
          if (score < bestScore) {
            bestScore = score;
            best = p;
          }
        }
      }
      // While the zoom moves, a node or mask run without its exact picture shows its own
      // prims (sharp at any scale) rather than a picture of another scale.
      const kind = this.items[i * ITEM_WORDS];
      const plain = moving && !exact && (kind === ITEM_NODE || kind === ITEM_MASK_RUN);
      const pic = exact ?? (plain ? null : best);
      if (pic) pic.used = this.frameNo;
      this.setRow(i, pic);
      if (exact) st.exact++;
      else if (best) st.standIn++;
      else st.none++;
      if (!exact && backdrop) {
        if (!moving) this.backdrops.add(i);
        continue;
      }
      // Smaller than a few pixels: what stands in will do.
      const area = (vi[o + 3] - vi[o + 1]) * (vi[o + 4] - vi[o + 2]);
      if (area < TINY_PX) continue;
      // Small ones with a stand-in wait until the view rests.
      if (!exact && best && !idle && area < SMALL_PX) {
        waiting++;
        continue;
      }
      if (!exact && (!moving || !best)) {
        const dx = (vi[o + 1] + vi[o + 3]) / 2 - cx;
        const dy = (vi[o + 2] + vi[o + 4]) / 2 - cy;
        want.push({ i, o, pri: Math.hypot(dx, dy), none: !best });
      }
    }
    want.sort((a, b) => Number(b.none) - Number(a.none) || a.pri - b.pri);
    const t0 = performance.now();
    let drawn = 0;
    for (const wnt of want) {
      if (drawn > 0 && performance.now() - t0 > budgetMs) break;
      const p = this.draw(engine, wnt.i, w, h);
      drawn++;
      if (p) this.setRow(wnt.i, p);
    }
    st.drawn = drawn;
    st.drawMs = performance.now() - t0;
    // Background blurs read what items drew: taken once the items are in.
    if (want.length > drawn) this.backdrops.clear();
    return want.length <= drawn && waiting === 0;
  }

  /** Background blur `i` taken from `target` (where the frame stands now) into the atlas,
   * recorded into `enc` (the frame's render pass ended first). */
  drawBackdrop(engine: Engine, i: number, enc: GPUCommandEncoder, target: GPUTexture, w: number, h: number, cam: number[]): void {
    const out = engine.recItem(this.page, i, w, h, 0, 0);
    const res = this.gpu.runScenePasses(engine, out.scene, enc, target);
    const key = this.keys[i];
    let list = this.pics.get(key);
    if (!list) this.pics.set(key, (list = []));
    if (list.length >= 3) {
      list.sort((a, b) => a.used - b.used);
      list.shift();
    }
    const scale = Math.hypot(out.ctm[0], out.ctm[1]);
    if (!res) {
      const p: Pic = { ctm: out.ctm, rect: [0, 0, 0, 0], whole: false, layer: 0, ax: 0, ay: 0, w: 0, h: 0, used: this.frameNo, scale, cam, epoch: this.epoch };
      list.push(p);
      this.setRow(i, p);
      return;
    }
    const pw = res.rect[2] - res.rect[0];
    const ph = res.rect[3] - res.rect[1];
    // Away from the target's edges the blur read everything it reads: whole-pixel pans
    // keep it. At an edge it holds only while the view stays.
    const whole = res.rect[0] > -cam[0] && res.rect[1] > -cam[1] && res.rect[2] < w - cam[0] && res.rect[3] < h - cam[1];
    this.stats.backdrops++;
    const slot = pw <= ATLAS && ph <= ATLAS ? this.alloc(pw, ph) : null;
    if (!slot) {
      this.gpu.releaseTarget(res.texture);
      return;
    }
    this.blit(enc, res.texture, slot, pw, ph);
    this.gpu.releaseTarget(res.texture);
    const p: Pic = { ctm: out.ctm, rect: res.rect, whole, layer: slot.layer, ax: slot.ax, ay: slot.ay, w: pw, h: ph, used: this.frameNo, scale, cam, epoch: this.epoch };
    list.push(p);
    this.layerUsed[slot.layer] = this.frameNo;
    this.setRow(i, p);
  }

  /** In-frame item `i` drawn onto `target` where the frame stands. */
  drawInFrame(engine: Engine, i: number, enc: GPUCommandEncoder, target: GPUTexture, w: number, h: number): void {
    const out = engine.recItem(this.page, i, w, h, 0, 0);
    this.gpu.encodeSceneOnto(engine, out.scene, enc, target);
  }

  isInFrame(i: number): boolean {
    return this.items[i * ITEM_WORDS] === ITEM_INFRAME;
  }

  private blit(enc: GPUCommandEncoder, src: GPUTexture, slot: { layer: number; ax: number; ay: number }, pw: number, ph: number): void {
    const u = this.device.createBuffer({ size: 16, usage: GPUBufferUsage.UNIFORM, mappedAtCreation: true });
    new Int32Array(u.getMappedRange()).set([slot.ax, slot.ay, 0, 0]);
    u.unmap();
    this.gpu.doomBuffer(u);
    const pass = enc.beginRenderPass({ colorAttachments: [{ view: this.atlas.createView({ dimension: "2d", baseArrayLayer: slot.layer, arrayLayerCount: 1 }), loadOp: "load", storeOp: "store" }] });
    pass.setPipeline(this.blitPipeline);
    pass.setBindGroup(0, this.device.createBindGroup({ layout: this.blitLayout, entries: [{ binding: 0, resource: src.createView() }, { binding: 1, resource: { buffer: u } }] }));
    pass.setViewport(slot.ax, slot.ay, pw, ph, 0, 1);
    pass.setScissorRect(slot.ax, slot.ay, pw, ph);
    pass.draw(3);
    pass.end();
  }

  /** Item `i` drawn at the last frame's camera into the atlas. */
  private draw(engine: Engine, i: number, w: number, h: number): Pic | null {
    const tb = performance.now();
    // What renders before wanted is theirs: asked for now, so what follows is the item's.
    const feed = feedOf(engine);
    feed?.takeWanted();
    const out = engine.recItem(this.page, i, w, h, MARGIN, WHOLE_PX);
    this.timing.build += performance.now() - tb;
    // Images the item lacks are asked for; its picture is drawn again once one comes.
    const hashes = feed?.takeWanted() ?? [];
    const lacked = hashes.length ? { at: feed!.installed, hashes } : undefined;
    const rect = out.rect;
    const pw = rect[2] - rect[0];
    const ph = rect[3] - rect[1];
    const whole = !out.cut;
    const key = this.keys[i];
    let list = this.pics.get(key);
    if (!list) this.pics.set(key, (list = []));
    // At most a few matrices of an item kept: the least recently shown goes.
    if (list.length >= 3) {
      list.sort((a, b) => a.used - b.used);
      list.shift();
    }
    const scale = Math.hypot(out.ctm[0], out.ctm[1]);
    if (pw <= 0 || ph <= 0) {
      const p: Pic = { ctm: out.ctm, rect, whole, layer: 0, ax: 0, ay: 0, w: 0, h: 0, used: this.frameNo, scale };
      list.push(p);
      return p;
    }
    if (pw > ATLAS || ph > ATLAS) return null;
    const slot = this.alloc(pw, ph);
    if (!slot) return null;
    const temp = this.gpu.tempTarget(pw, ph);
    const enc = this.device.createCommandEncoder();
    const te = performance.now();
    this.gpu.encodeSceneInto(engine, out.scene, enc, temp, lacked === undefined);
    this.blit(enc, temp, slot, pw, ph);
    this.device.queue.submit([enc.finish()]);
    this.timing.encode += performance.now() - te;
    this.timing.n++;
    this.gpu.releaseTarget(temp);
    this.epoch++;
    const p: Pic = { ctm: out.ctm, rect, whole, layer: slot.layer, ax: slot.ax, ay: slot.ay, w: pw, h: ph, used: this.frameNo, scale, lacked };
    list.push(p);
    this.layerUsed[slot.layer] = this.frameNo;
    return p;
  }

  /** A place in the atlas for `w` x `h` texels (shelves; a layer least recently used is
   * emptied when all are full). */
  private alloc(w: number, h: number): { layer: number; ax: number; ay: number } | null {
    const pad = 1;
    const ww = w + pad;
    const hh = h + pad;
    for (let pass = 0; pass < 3; pass++) {
      for (let l = 0; l < this.atlas.depthOrArrayLayers; l++) {
        const shelves = this.shelves[l];
        for (const s of shelves) {
          if (s.h >= hh && s.h <= hh * 1.5 + 8 && s.x + ww <= ATLAS) {
            const at = { layer: l, ax: s.x, ay: s.y };
            s.x += ww;
            return at;
          }
        }
        const last = shelves[shelves.length - 1];
        const y = last ? last.y + last.h : 0;
        if (y + hh <= ATLAS && ww <= ATLAS) {
          shelves.push({ y, h: hh, x: ww });
          return { layer: l, ax: 0, ay: y };
        }
      }
      if (pass === 0 && this.atlas.depthOrArrayLayers < MAX_LAYERS) {
        this.grow(Math.min(MAX_LAYERS, this.atlas.depthOrArrayLayers + 1));
        continue;
      }
      // Full: the layer shown longest ago starts over (its pictures go).
      let oldest = 0;
      for (let l = 1; l < this.atlas.depthOrArrayLayers; l++) if (this.layerUsed[l] < this.layerUsed[oldest]) oldest = l;
      if (this.layerUsed[oldest] >= this.frameNo) return null;
      this.emptyLayer(oldest);
    }
    return null;
  }

  private emptyLayer(l: number): void {
    this.shelves[l] = [];
    for (const [key, list] of this.pics) {
      const keep = list.filter((p) => p.w === 0 || p.layer !== l);
      if (keep.length !== list.length) {
        if (keep.length) this.pics.set(key, keep);
        else this.pics.delete(key);
      }
    }
    for (let i = 0; i < this.chosen.length; i++) {
      const c = this.chosen[i];
      if (c && c.w > 0 && c.layer === l) this.setRow(i, null);
    }
  }

  private grow(layers: number): void {
    const old = this.atlas;
    const t = this.makeAtlas(layers);
    const enc = this.device.createCommandEncoder();
    enc.copyTextureToTexture({ texture: old }, { texture: t }, [ATLAS, ATLAS, old.depthOrArrayLayers]);
    this.device.queue.submit([enc.finish()]);
    this.gpu.doom(old);
    this.atlasTex = t;
  }

  /** Bytes the atlas takes. */
  bytes(): number {
    return ATLAS * ATLAS * 4 * (this.atlasTex?.depthOrArrayLayers ?? 0);
  }
}

function sameCtm(a: number[], b: number[]): boolean {
  const tol = 1e-5 * Math.max(Math.abs(b[0]) + Math.abs(b[1]), Math.abs(b[2]) + Math.abs(b[3]));
  for (let k = 0; k < 4; k++) if (Math.abs(fr(a[k]) - fr(b[k])) > tol) return false;
  return Math.abs(a[4] - b[4]) <= 1e-3 && Math.abs(a[5] - b[5]) <= 1e-3;
}
