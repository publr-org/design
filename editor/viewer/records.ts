// The GPU canvas from records (docs/gpu.md "Records"): a page's records, written once by
// the engine in its nodes' units, kept in GPU buffers; a frame writes one camera per
// top-level node and draws the runs of those in view. Panning and zooming change only
// the cameras; nothing is built per frame or per scale.
//
// This is glue, not UI: buffers, textures and the frame's passes.

import type { Engine } from "./engine";
import type { GpuCanvas, GpuStats } from "./gpu";
import { ItemCache, TABLE_WORDS } from "./items";
import { feedOf } from "./feed";

const NONE = 0xffffffff;
const TARGET_FORMAT: GPUTextureFormat = "rgba16float";

/** Header fields (u32 words), records.zig `Header`. */
const H = {
  prims: 1,
  primCount: 2,
  shapes: 3,
  shapeCount: 4,
  paints: 5,
  paintCount: 6,
  stops: 7,
  stopCount: 8,
  xforms: 9,
  xformCount: 10,
  curves: 11,
  curveCount: 12,
  paths: 13,
  pathCount: 14,
  bands: 15,
  bandCount: 16,
  bandItems: 17,
  bandItemCount: 18,
  draws: 19,
  drawCount: 20,
  tops: 21,
  topCount: 22,
  images: 23,
  imageCount: 24,
  masks: 25,
  maskCount: 26,
  items: 27,
  itemCount: 28,
  full: 29,
  nodes: 30,
  glyphs: 31,
  approximated: 32,
} as const;
const HEADER_WORDS = 45;
/** Room the GPU buffers keep for records an edit adds (a fraction of what they hold). */
const SLACK = 1.25;
/** The lists kept in buffers of their own: header fields and record sizes. */
const LISTS = [
  ["prims", H.prims, H.primCount, 64],
  ["shapes", H.shapes, H.shapeCount, 128],
  ["paints", H.paints, H.paintCount, 64],
  ["stops", H.stops, H.stopCount, 16],
  ["xforms", H.xforms, H.xformCount, 32],
  ["curves", H.curves, H.curveCount, 32],
] as const;
/** The sections of the `geo` buffer (u32 words): paths, bands, the bands' curves, masks. */
const GEO = [
  [H.paths, H.pathCount, 8],
  [H.bands, H.bandCount, 2],
  [H.bandItems, H.bandItemCount, 1],
  [H.masks, H.maskCount, 8],
] as const;
/** Side of a path's coverage mask, texels (records.zig `mask_size`), and its levels. */
const MASK_SIZE = 2048;
const MASK_LEVELS = 12;

/** A mask level from the one above: the mean of its four texels. */
const DOWN_WGSL = `
@group(0) @binding(0) var src: texture_2d<f32>;
@vertex fn vs(@builtin(vertex_index) vi: u32) -> @builtin(position) vec4f {
  let p = vec2f(f32((vi << 1u) & 2u), f32(vi & 2u));
  return vec4f(p * 2.0 - 1.0, 0.0, 1.0);
}
@fragment fn fs(@builtin(position) pos: vec4f) -> @location(0) vec4f {
  let p = vec2i(floor(pos.xy)) * 2;
  let a = textureLoad(src, p, 0).r + textureLoad(src, p + vec2i(1, 0), 0).r + textureLoad(src, p + vec2i(0, 1), 0).r + textureLoad(src, p + vec2i(1, 1), 0).r;
  return vec4f(a * 0.25);
}`;
/** Bytes of each record. */
const SIZES = { prim: 64, shape: 128, paint: 64, stop: 16, xform: 32, curve: 32, path: 32, band: 8, item: 4, camera: 32, held: 16 };
const DRAW_WORDS = 8;
const TOP_WORDS = 8;

/** One image's texture as the engine holds it now. */
type ImageTex = { texture: GPUTexture; group: GPUBindGroup; first: number; levels: number; width: number; height: number; bytes: number };

/** The records of a page, uploaded. */
type Built = {
  page: number;
  gen: number;
  bufs: Record<string, GPUBuffer>;
  /** Draw runs: kind, first, count, tex, flags, top (copied out of the engine). */
  draws: Uint32Array;
  /** Per top-level node: draw first, draw count, prim first, prim count. */
  tops: Uint32Array;
  topCount: number;
  imageCount: number;
  prims: number;
  group: GPUBindGroup | null;
  ms: number;
  stats: { nodes: number; glyphs: number; approximated: number; bytes: number };
};

export class RecordsCanvas {
  readonly gpu: GpuCanvas;
  /** The page these records are of (each kept page has its own). */
  readonly page: number;
  readonly device: GPUDevice;
  private layout0: GPUBindGroupLayout;
  private layout1: GPUBindGroupLayout;
  private pipeline: GPURenderPipeline;
  private uniform: GPUBuffer;
  /** The frame's cameras, then the images' held state (`framebuf` in records.wgsl). */
  private frameBuf: GPUBuffer | null = null;
  private maskTex: GPUTexture | null = null;
  private heldData = new Uint32Array(0);
  private built: Built | null = null;
  private maskLayout: GPUBindGroupLayout;
  private downLayout: GPUBindGroupLayout;
  private maskPipeline: GPURenderPipeline;
  private downPipeline: GPURenderPipeline;
  private sampler: GPUSampler;
  private masksOff = 0;
  private itemsOff = 0;
  readonly items: ItemCache;
  private groupAtlasGen = -1;
  private heldOff = 0;
  private bandsOff = 0;
  private bandItemsOff = 0;
  private images = new Map<number, ImageTex>();
  private dummyGroup: GPUBindGroup;
  /** Bumped when the document changes (records and images go). */
  gen = 0;
  /** The page needs its records written again (an edit, a font). */
  dirty = false;
  stats: GpuStats;
  /** What the last frame lacked (images on their way): the stage draws again. */
  lacking = false;
  frameNo = 0;

  constructor(gpu: GpuCanvas, engine: Engine, page: number) {
    this.gpu = gpu;
    this.page = page;
    const device = (this.device = gpu.device);
    this.stats = { ...gpu.stats };
    // Pipelines and layouts are the device's, shared by every document's canvas.
    const kit = kitFor(device, engine);
    this.layout0 = kit.layout0;
    this.layout1 = kit.layout1;
    this.maskLayout = kit.maskLayout;
    this.downLayout = kit.downLayout;
    this.sampler = kit.sampler;
    this.pipeline = kit.pipeline;
    this.maskPipeline = kit.maskPipeline;
    this.downPipeline = kit.downPipeline;
    this.dummyGroup = kit.dummyGroup;
    this.items = new ItemCache(gpu, page);
    this.uniform = device.createBuffer({ size: 48, usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST });
  }


  /** Gives up everything on the GPU (the document is no longer kept). */
  destroy(): void {
    this.clear();
    this.maskTex?.destroy();
    this.maskTex = null;
    this.frameBuf?.destroy();
    this.frameBuf = null;
    this.items.destroy();
  }

  /** Forgets the records and images (the document or its fonts changed). */
  clear(): void {
    this.gen++;
    this.writing = false;
    this.items.clear();
    this.drop();
    for (const t of this.images.values()) t.texture.destroy();
    this.images.clear();
  }

  private drop(): void {
    const b = this.built;
    if (!b) return;
    for (const buf of Object.values(b.bufs)) buf.destroy();
    this.built = null;
  }

  /** Whether page `page`'s records are on the GPU and current. */
  has(page: number): boolean {
    return page === this.page && !this.writing && !!this.built && this.built.gen === this.gen;
  }

  /** Writes the page's records and uploads them. */
  build(engine: Engine): void {
    this.dirty = false;
    this.writing = false;
    this.uploadAll(engine, engine.recBuild(this.page), this.page);
  }

  /** The records are being written a few top-level nodes a frame (`buildSome`). */
  writing = false;
  private writeMs = 0;

  /** Writes the page's records for about `budgetMs` (a top-level node at least) and
   * uploads them once all are written; true then. The thread keeps its frames while a
   * big page is written (images decoded elsewhere come in between). */
  buildSome(engine: Engine, budgetMs: number): boolean {
    const t0 = performance.now();
    if (!this.writing) {
      this.dirty = false;
      engine.recBegin(this.page);
      this.writing = true;
      this.writeMs = 0;
    }
    let hdr = 0;
    do hdr = engine.recStep(this.page, 1);
    while (!hdr && performance.now() - t0 < budgetMs);
    this.writeMs += performance.now() - t0;
    if (!hdr) return false;
    this.writing = false;
    this.uploadAll(engine, hdr, this.page);
    console.info(`records: page ${this.page} written in ${Math.round(this.writeMs)} ms of this thread`);
    return true;
  }

  /** Brings the records up to date after edits: the top-level nodes changed are written
   * again at the ends of the lists and only those ends uploaded (everything, when the
   * engine wrote the page whole; the paints alone, when only colours changed). */
  refresh(engine: Engine): void {
    const page = this.page;
    this.dirty = false;
    const t0 = performance.now();
    const hdr = engine.recUpdate(page);
    const head = new Uint32Array(engine.memory.buffer, hdr, HEADER_WORDS).slice();
    const t1 = performance.now();
    this.updates.push([head[H.full], Math.round((t1 - t0) * 10) / 10]);
    if (this.updates.length > 200) this.updates.shift();
    if (head[H.full] === 2) return;
    if (head[H.full] === 1 || head[H.maskCount] !== this.counts.masks || !this.built) {
      this.uploadAll(engine, hdr, page);
      return;
    }
    if (head[H.full] === 4) this.uploadColours(engine, head);
    else this.uploadTails(engine, head, head[H.full] === 3);
    this.lastRefreshMs = performance.now() - t0;
  }

  /** Colours alone changed (`full` 4): the paints and stops painted again in place,
   * uploaded whole, and the items' keys made again (their pictures are drawn anew). */
  private uploadColours(engine: Engine, head: Uint32Array): void {
    const b = this.built!;
    const mem = engine.memory.buffer;
    for (const [name, ptr, count, size] of LISTS) {
      if (name !== "paints" && name !== "stops") continue;
      const n = head[count];
      if (n) this.device.queue.writeBuffer(b.bufs[name], 0, new Uint8Array(mem, head[ptr], n * size));
    }
    this.items.setItems(engine, head[H.items], head[H.itemCount], false);
  }

  /** The last updates: how (`full`) and the engine's ms (checks). */
  updates: number[][] = [];
  /** How long the last edit's update took, ms. */
  lastRefreshMs = 0;
  /** Records uploaded per list (what an update's tail starts from). */
  private counts: Record<string, number> = {};
  /** Capacity of the `geo` sections (words) and their offsets. */
  private geoCap = [0, 0, 0, 0];
  private geoOff = [0, 0, 0, 0];
  private heldCap = 0;
  private itemCap = 0;

  private uploadAll(engine: Engine, hdr: number, page: number): void {
    const t0 = performance.now();
    this.drop();
    const mem = engine.memory.buffer;
    const head = new Uint32Array(mem, hdr, HEADER_WORDS).slice();
    const device = this.device;
    const bufs: Record<string, GPUBuffer> = {};
    let bytes = 0;
    for (const [name, ptr, count, size] of LISTS) {
      const n = head[count];
      const len = Math.max(64, Math.ceil(n * size * SLACK));
      const buf = device.createBuffer({ size: Math.ceil(len / 16) * 16, usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_DST | GPUBufferUsage.COPY_SRC });
      if (n) device.queue.writeBuffer(buf, 0, new Uint8Array(mem, head[ptr], n * size));
      bufs[name] = buf;
      this.counts[name] = n;
      bytes += buf.size;
    }
    bufs.geo = this.layoutGeo(engine, head);
    bytes += bufs.geo.size;
    const maskCount = head[H.maskCount];
    this.counts.masks = maskCount;
    this.masksOff = this.geoOff[3];
    this.bandsOff = this.geoOff[1];
    this.bandItemsOff = this.geoOff[2];
    // Each heavy path's coverage, drawn once into a layer of the mask texture, its levels
    // averaged down.
    const maskTex = device.createTexture({ size: [MASK_SIZE, MASK_SIZE, Math.max(1, maskCount)], format: "r8unorm", mipLevelCount: MASK_LEVELS, usage: GPUTextureUsage.RENDER_ATTACHMENT | GPUTextureUsage.TEXTURE_BINDING });
    this.maskTex?.destroy();
    this.maskTex = maskTex;
    bytes += Math.max(1, maskCount) * MASK_SIZE * MASK_SIZE * 1.34;
    if (maskCount) this.drawMasks(new Uint32Array(mem, head[H.masks], maskCount * 8).slice(), bufs.curves, bufs.geo);
    const topCount = head[H.topCount];
    const imageCount = head[H.imageCount];
    const itemCount = head[H.itemCount];
    // Cameras first (two vec4s per top-level node), the images' held state, the items'.
    this.heldOff = topCount * 2;
    this.heldCap = Math.max(16, Math.ceil(imageCount * SLACK));
    this.itemsOff = this.heldOff + this.heldCap;
    this.itemCap = Math.max(64, Math.ceil(itemCount * SLACK));
    this.items.setItems(engine, head[H.items], itemCount, false);
    this.frameBuf?.destroy();
    this.frameBuf = device.createBuffer({ size: (this.itemsOff + this.itemCap * (TABLE_WORDS / 4)) * 16, usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_DST });
    this.heldData = new Uint32Array(this.heldCap * 4);
    device.queue.writeBuffer(this.frameBuf, this.heldOff * 16, this.heldData);
    // Images of the last build are another page's numbering: dropped.
    for (const t of this.images.values()) t.texture.destroy();
    this.images.clear();
    this.built = {
      page,
      gen: this.gen,
      bufs,
      draws: new Uint32Array(mem, head[H.draws], head[H.drawCount] * DRAW_WORDS).slice(),
      tops: new Uint32Array(mem, head[H.tops], topCount * TOP_WORDS).slice(),
      topCount,
      imageCount,
      prims: head[H.primCount],
      group: null,
      ms: performance.now() - t0,
      stats: { nodes: head[H.nodes], glyphs: head[H.glyphs], approximated: head[H.approximated], bytes },
    };
    this.makeGroup();
    console.info(`records: page ${page} written and uploaded in ${Math.round(this.built.ms)} ms (${head[H.primCount]} prims, ${head[H.glyphs]} glyphs, ${head[H.curveCount]} curves, ${itemCount} items, ${Math.round(bytes / 1048576)} MB, ${head[H.approximated]} nodes approximated)`);
  }

  /** The `geo` buffer laid out afresh with room in each section, written whole. */
  private layoutGeo(engine: Engine, head: Uint32Array): GPUBuffer {
    const mem = engine.memory.buffer;
    let at = 0;
    for (let k = 0; k < GEO.length; k++) {
      const [, count, words] = GEO[k];
      this.geoOff[k] = at;
      this.geoCap[k] = Math.max(16, Math.ceil(head[count] * SLACK)) * words;
      at += this.geoCap[k];
    }
    const geo = this.device.createBuffer({ size: Math.ceil((at * 4) / 16) * 16, usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_DST });
    for (let k = 0; k < GEO.length; k++) {
      const [ptr, count, words] = GEO[k];
      if (head[count]) this.device.queue.writeBuffer(geo, this.geoOff[k] * 4, new Uint8Array(mem, head[ptr], head[count] * words * 4));
    }
    this.counts.paths = head[H.pathCount];
    this.counts.bands = head[H.bandCount];
    this.counts.bandItems = head[H.bandItemCount];
    return geo;
  }

  /** What an edit added at the ends of the lists, uploaded (buffers outgrown are made
   * again, larger, their old contents copied). `rewritten` (`full` 3): the lists but the
   * curves and the geo sections were written again from their starts, uploaded whole. */
  private uploadTails(engine: Engine, head: Uint32Array, rewritten = false): void {
    const b = this.built!;
    const mem = engine.memory.buffer;
    const device = this.device;
    let regroup = false;
    const enc = device.createCommandEncoder();
    for (const [name, ptr, count, size] of LISTS) {
      const n = head[count];
      const was = rewritten && name !== "curves" ? 0 : this.counts[name];
      if (n <= was) {
        this.counts[name] = n;
        continue;
      }
      let buf = b.bufs[name];
      if (n * size > buf.size) {
        const bigger = device.createBuffer({ size: Math.ceil((Math.max(n * size * SLACK, buf.size * 1.5)) / 16) * 16, usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_DST | GPUBufferUsage.COPY_SRC });
        if (was) enc.copyBufferToBuffer(buf, 0, bigger, 0, was * size);
        this.gpu.doomBuffer(buf);
        b.bufs[name] = buf = bigger;
        regroup = true;
      }
      device.queue.writeBuffer(buf, was * size, new Uint8Array(mem, head[ptr] + was * size, (n - was) * size));
      this.counts[name] = n;
    }
    device.queue.submit([enc.finish()]);
    // The geo sections: tails, or laid out again when one outgrew its room.
    const fits = GEO.every(([, count, words], k) => head[count] * words <= this.geoCap[k]);
    if (!fits) {
      this.gpu.doomBuffer(b.bufs.geo);
      b.bufs.geo = this.layoutGeo(engine, head);
      this.bandsOff = this.geoOff[1];
      this.bandItemsOff = this.geoOff[2];
      this.masksOff = this.geoOff[3];
      regroup = true;
    } else {
      const names = ["paths", "bands", "bandItems"];
      for (let k = 0; k < 3; k++) {
        const [ptr, count, words] = GEO[k];
        const n = head[count];
        const was = this.counts[names[k]];
        if (n > was) device.queue.writeBuffer(b.bufs.geo, (this.geoOff[k] + was * words) * 4, new Uint8Array(mem, head[ptr] + was * words * 4, (n - was) * words * 4));
        this.counts[names[k]] = n;
      }
    }
    // Images and items added: the frame buffer's sections, larger when outgrown.
    const imageCount = head[H.imageCount];
    const itemCount = head[H.itemCount];
    if (imageCount > this.heldCap || itemCount > this.itemCap) {
      this.heldCap = Math.max(this.heldCap, Math.ceil(imageCount * SLACK));
      this.itemsOff = this.heldOff + this.heldCap;
      this.itemCap = Math.max(this.itemCap, Math.ceil(itemCount * SLACK));
      this.gpu.doomBuffer(this.frameBuf!);
      this.frameBuf = device.createBuffer({ size: (this.itemsOff + this.itemCap * (TABLE_WORDS / 4)) * 16, usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_DST });
      const held = new Uint32Array(this.heldCap * 4);
      held.set(this.heldData.subarray(0, Math.min(this.heldData.length, held.length)));
      this.heldData = held;
      device.queue.writeBuffer(this.frameBuf, this.heldOff * 16, this.heldData);
      this.items.dirtyLo = 0;
      this.items.dirtyHi = Math.max(0, itemCount - 1);
      regroup = true;
    } else if (imageCount * 4 > this.heldData.length) {
      const held = new Uint32Array(this.heldCap * 4);
      held.set(this.heldData);
      this.heldData = held;
    }
    this.items.setItems(engine, head[H.items], itemCount, !rewritten);
    b.draws = new Uint32Array(mem, head[H.draws], head[H.drawCount] * DRAW_WORDS).slice();
    b.tops = new Uint32Array(mem, head[H.tops], b.topCount * TOP_WORDS).slice();
    b.imageCount = imageCount;
    b.prims = head[H.primCount];
    b.stats.nodes = head[H.nodes];
    if (regroup) this.makeGroup();
  }

  /** The heavy paths' coverage masks drawn into their layers, levels averaged down. */
  private drawMasks(words: Uint32Array, curves: GPUBuffer, geo: GPUBuffer): void {
    const device = this.device;
    const maskTex = this.maskTex!;
    const enc = device.createCommandEncoder();
    const maskCount = words.length / 8;
    for (let mi = 0; mi < maskCount; mi++) {
      const u = new ArrayBuffer(48);
      // The path's bands are read through the same offsets a frame uses.
      new Uint32Array(u, 16, 6).set([this.heldOff, this.bandsOff, this.bandItemsOff, 0, this.masksOff, mi]);
      const ub = device.createBuffer({ size: 48, usage: GPUBufferUsage.UNIFORM, mappedAtCreation: true });
      new Uint8Array(ub.getMappedRange()).set(new Uint8Array(u));
      ub.unmap();
      this.gpu.doomBuffer(ub);
      const g = device.createBindGroup({
        layout: this.maskLayout,
        entries: [
          { binding: 0, resource: { buffer: ub } },
          { binding: 7, resource: { buffer: curves } },
          { binding: 8, resource: { buffer: geo } },
        ],
      });
      const layer = words[mi * 8 + 1];
      const pass = enc.beginRenderPass({ colorAttachments: [{ view: maskTex.createView({ dimension: "2d", baseArrayLayer: layer, arrayLayerCount: 1, baseMipLevel: 0, mipLevelCount: 1 }), loadOp: "clear", storeOp: "store", clearValue: [0, 0, 0, 0] }] });
      pass.setPipeline(this.maskPipeline);
      pass.setBindGroup(0, g);
      pass.draw(3);
      pass.end();
      for (let l = 1; l < MASK_LEVELS; l++) {
        const src = maskTex.createView({ dimension: "2d", baseArrayLayer: layer, arrayLayerCount: 1, baseMipLevel: l - 1, mipLevelCount: 1 });
        const dst = maskTex.createView({ dimension: "2d", baseArrayLayer: layer, arrayLayerCount: 1, baseMipLevel: l, mipLevelCount: 1 });
        const p = enc.beginRenderPass({ colorAttachments: [{ view: dst, loadOp: "clear", storeOp: "store", clearValue: [0, 0, 0, 0] }] });
        p.setPipeline(this.downPipeline);
        p.setBindGroup(0, device.createBindGroup({ layout: this.downLayout, entries: [{ binding: 0, resource: src }] }));
        p.draw(3);
        p.end();
      }
    }
    device.queue.submit([enc.finish()]);
  }

  /** The bind group of the records' buffers (made again when the item atlas grows). */
  private makeGroup(): void {
    const b = this.built!;
    const bufs = b.bufs;
    const device = this.device;
    this.groupAtlasGen = this.items.atlasGen;
    b.group = device.createBindGroup({
      layout: this.layout0,
      entries: [
        { binding: 0, resource: { buffer: this.uniform } },
        { binding: 1, resource: { buffer: bufs.prims } },
        { binding: 2, resource: { buffer: bufs.shapes } },
        { binding: 3, resource: { buffer: bufs.paints } },
        { binding: 4, resource: { buffer: bufs.stops } },
        { binding: 5, resource: { buffer: bufs.xforms } },
        { binding: 6, resource: { buffer: this.frameBuf } },
        { binding: 7, resource: { buffer: bufs.curves } },
        { binding: 8, resource: { buffer: bufs.geo } },
        { binding: 9, resource: this.maskTex!.createView({ dimension: "2d-array" }) },
        { binding: 10, resource: this.sampler },
        { binding: 11, resource: this.items.atlas.createView({ dimension: "2d-array" }) },
      ],
    });
  }

  /** Image `index`'s texture as the engine holds it now (made again when a finer chain
   * came); null while none is held. */
  private image(engine: Engine, index: number): ImageTex | null {
    const held = engine.recHeld(this.page, index);
    const have = this.images.get(index);
    if (!held) return have ?? null;
    if (have && have.first === held.first && have.levels === held.levels) return have;
    const device = this.device;
    const texture = device.createTexture({ size: [held.width, held.height], format: "rgba8unorm", mipLevelCount: held.levels, usage: GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.COPY_DST });
    let bytes = 0;
    for (let l = 0; l < held.levels; l++) {
      const lv = engine.recLevel(this.page, index, l);
      const data = new Uint8Array(engine.memory.buffer, lv.ptr, lv.width * lv.height * 4);
      device.queue.writeTexture({ texture, mipLevel: l }, data, { bytesPerRow: lv.width * 4 }, [lv.width, lv.height]);
      bytes += data.length;
    }
    if (have) this.gpu.doom(have.texture);
    this.items.epoch++;
    const t: ImageTex = { texture, group: device.createBindGroup({ layout: this.layout1, entries: [{ binding: 0, resource: texture.createView() }] }), first: held.first, levels: held.levels, width: held.width, height: held.height, bytes };
    this.images.set(index, t);
    const o = index * 4;
    const f = new Float32Array(this.heldData.buffer);
    f[o] = held.width;
    f[o + 1] = held.height;
    this.heldData[o + 2] = held.first + held.levels;
    this.heldData[o + 3] = 1;
    device.queue.writeBuffer(this.frameBuf!, (this.heldOff + index) * 16, this.heldData, o, 4);
    return t;
  }

  /** Draws page `page` with world (x, y) at the canvas's top left at `scale` device
   * pixels per unit, over `background`. False when the records are not written yet. */
  draw(engine: Engine, page: number, x: number, y: number, scale: number, background: number[], present = true, moving = false, budgetMs = 6, idle = true): boolean {
    const b = this.built;
    if (!b || !this.has(page)) return false;
    const t0 = performance.now();
    this.frameNo++;
    const device = this.device;
    const w = this.gpu.canvas.width;
    const h = this.gpu.canvas.height;
    const fhAt = engine.recFrame(page, x, y, scale, w, h);
    const fh = new Uint32Array(engine.memory.buffer, fhAt, 6).slice();
    const mem = engine.memory.buffer;
    device.queue.writeBuffer(this.frameBuf!, 0, new Uint8Array(mem, fh[0], fh[1] * SIZES.camera));
    const visible = new Uint32Array(mem, fh[2], fh[3]).slice();
    const cams = new Float32Array(mem, fh[0], fh[1] * 8).slice();
    const vItems = new Uint32Array(mem, fh[4], fh[5] * 12).slice();
    const t1 = performance.now();
    // Items: pictures chosen, new ones drawn (each its own submit, before this frame's).
    const epoch0 = this.items.epoch;
    const itemsWhole = this.items.update(engine, vItems, fh[5], cams, w, h, moving, budgetMs, idle);
    if (this.items.atlasGen !== this.groupAtlasGen) this.makeGroup();
    const it = this.items;
    if (it.dirtyHi >= it.dirtyLo) {
      device.queue.writeBuffer(this.frameBuf!, this.itemsOff * 16 + it.dirtyLo * TABLE_WORDS * 4, it.table, it.dirtyLo * TABLE_WORDS, (it.dirtyHi - it.dirtyLo + 1) * TABLE_WORDS);
      it.dirtyLo = Infinity;
      it.dirtyHi = -1;
    }
    const t1b = performance.now();
    const u = new ArrayBuffer(48);
    new Float32Array(u, 0, 2).set([w, h]);
    new Uint32Array(u, 16, 7).set([this.heldOff, this.bandsOff, this.bandItemsOff, (globalThis as { __rdbg?: number }).__rdbg ?? 0, this.masksOff, 0, this.itemsOff]);
    device.queue.writeBuffer(this.uniform, 0, u);
    const target = targetFor(device, w, h);
    let encoder = device.createCommandEncoder();
    const begin = (load: boolean) => {
      const p = encoder.beginRenderPass({
        colorAttachments: [{ view: target.createView(), loadOp: load ? "load" : "clear", storeOp: "store", clearValue: [background[0], background[1], background[2], 1] }],
      });
      p.setPipeline(this.pipeline);
      p.setBindGroup(0, b.group!);
      return p;
    };
    let pass = begin(false);
    let drawCalls = 0;
    let prims = 0;
    let lacking = false;
    let bound: GPUBindGroup | null = null;
    const it2 = this.items;
    const camsI = new Int32Array(cams.buffer);
    for (const ti of visible) {
      const to = ti * TOP_WORDS;
      const first = b.tops[to];
      const count = b.tops[to + 1];
      // Background blurs to take from the target in this node: the pass breaks there.
      const blurs = it2.backdrops.size || it2.inframe.size ? (it2.backdropsOf.get(ti) ?? []).filter((x) => it2.backdrops.has(x[1]) || it2.inframe.has(x[1])) : [];
      let bi = 0;
      for (let d = first; d < first + count; d++) {
        const o = d * DRAW_WORDS;
        const tex = b.draws[o + 3];
        let group = this.dummyGroup;
        if (tex !== NONE) {
          const img = this.image(engine, tex);
          // Missing while it decodes (one that never comes, a damaged file, is not waited for).
          if (!img) {
            if (feedOf(engine)?.busy()) lacking = true;
          } else group = img.group;
        }
        let p0 = b.draws[o + 1];
        const p1 = p0 + b.draws[o + 2];
        while (p0 < p1) {
          let end = p1;
          const blur = bi < blurs.length && blurs[bi][0] < p1 ? blurs[bi] : null;
          if (blur) end = Math.max(p0, blur[0]);
          if (end > p0) {
            if (group !== bound) {
              pass.setBindGroup(1, group);
              bound = group;
            }
            pass.draw(4, end - p0, 0, p0);
            drawCalls++;
            prims += end - p0;
            p0 = end;
          }
          // Background blurs past this frame's budget wait for the next frame.
          if (blur && blur[0] === p0 && !it2.isInFrame(blur[1]) && performance.now() - t1b > budgetMs) {
            bi++;
            lacking = true;
            continue;
          }
          if (blur && blur[0] === p0) {
            // What the frame holds here, blurred into the item's picture; then on.
            pass.end();
            if (it2.isInFrame(blur[1])) {
              // The immediate builder's buffers are written per frame it draws: what came
              // before goes first, and the item in a submit of its own.
              device.queue.submit([encoder.finish()]);
              encoder = device.createCommandEncoder();
              it2.drawInFrame(engine, blur[1], encoder, target, w, h);
              device.queue.submit([encoder.finish()]);
              encoder = device.createCommandEncoder();
            } else it2.drawBackdrop(engine, blur[1], encoder, target, w, h, [camsI[ti * 8 + 6], camsI[ti * 8 + 7]]);
            if (it2.atlasGen !== this.groupAtlasGen) this.makeGroup();
            if (it2.dirtyHi >= it2.dirtyLo) {
              device.queue.writeBuffer(this.frameBuf!, this.itemsOff * 16 + it2.dirtyLo * TABLE_WORDS * 4, it2.table, it2.dirtyLo * TABLE_WORDS, (it2.dirtyHi - it2.dirtyLo + 1) * TABLE_WORDS);
              it2.dirtyLo = Infinity;
              it2.dirtyHi = -1;
            }
            pass = begin(true);
            bound = null;
            bi++;
          } else if (blur && blur[0] < p0) {
            bi++;
          }
        }
      }
    }
    pass.end();
    if (present) this.gpu.presentTexture(encoder, target);
    device.queue.submit([encoder.finish()]);
    this.gpu.afterFrame();
    const t2 = performance.now();
    // Something a background blur reads changed this frame: the next frame takes it again.
    const backdrops = this.items.backdropsOf.size > 0 && this.items.epoch !== epoch0;
    this.lacking = lacking || !itemsWhole || backdrops;
    if ((globalThis as { __recDebug?: unknown[] }).__recDebug) (globalThis as { __recDebug: unknown[] }).__recDebug.push([Math.round(t0), Math.round(performance.now() - t0), lacking, itemsWhole, backdrops, this.items.stats.drawn, this.items.stats.backdrops]);
    const st = this.stats;
    st.sceneMs = t1 - t0;
    st.encodeMs = t2 - t1b;
    st.surfaces = it.stats.visible;
    st.surfacesDrawn = it.stats.drawn;
    st.passes = Math.round(it.stats.drawMs * 10) / 10;
    st.drawCalls = drawCalls;
    st.prims = prims;
    st.nodes = b.stats.nodes;
    st.glyphs = b.stats.glyphs;
    st.glyphsNew = 0;
    st.pathEntries = 0;

    st.fallbacks = b.stats.approximated;
    st.pending = 0;
    st.glyphsDeferred = 0;
    let texBytes = b.stats.bytes;
    for (const i of this.images.values()) texBytes += i.bytes;
    st.textureBytes = texBytes + w * h * 8;
    const no = this.frameNo;
    void device.queue.onSubmittedWorkDone().then(() => {
      if (no === this.frameNo) this.stats.gpuMs = performance.now() - t2;
    });
    return true;
  }

  /** The last frame drawn, read back as straight RGBA8 (checks). */
  async readTarget(): Promise<{ width: number; height: number; data: Uint8ClampedArray }> {
    const t = targets.get(this.device)!;
    return this.gpu.readTexture(t);
  }

  /** Bytes these records hold on the GPU: lists, masks, the frame's tables, images and
   * item pictures. */
  gpuBytes(): number {
    let n = (this.built?.stats.bytes ?? 0) + (this.frameBuf?.size ?? 0) + this.items.bytes();
    for (const i of this.images.values()) n += i.bytes;
    return n;
  }
}

/** The texture frames are drawn into before they go on screen, one per device (every
 * page's records draw into it; one is shown at a time). */
const targets = new Map<GPUDevice, GPUTexture>();

function targetFor(device: GPUDevice, w: number, h: number): GPUTexture {
  const t = targets.get(device);
  if (t && t.width === w && t.height === h) return t;
  t?.destroy();
  const made = device.createTexture({ size: [w, h], format: TARGET_FORMAT, usage: GPUTextureUsage.RENDER_ATTACHMENT | GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.COPY_SRC });
  targets.set(device, made);
  return made;
}

/** What every records canvas of a device shares: layouts, pipelines, a sampler. */
type Kit = {
  layout0: GPUBindGroupLayout;
  layout1: GPUBindGroupLayout;
  maskLayout: GPUBindGroupLayout;
  downLayout: GPUBindGroupLayout;
  sampler: GPUSampler;
  pipeline: GPURenderPipeline;
  maskPipeline: GPURenderPipeline;
  downPipeline: GPURenderPipeline;
  dummyGroup: GPUBindGroup;
};

const kits = new WeakMap<GPUDevice, Kit>();

function kitFor(device: GPUDevice, engine: Engine): Kit {
  const have = kits.get(device);
  if (have) return have;
  const k = {} as Kit;
  const F = GPUShaderStage.FRAGMENT;
  const V = GPUShaderStage.VERTEX;
  const storage = (binding: number, visibility: number): GPUBindGroupLayoutEntry => ({ binding, visibility, buffer: { type: "read-only-storage" } });
  k.layout0 = device.createBindGroupLayout({
    entries: [
      { binding: 0, visibility: V | F, buffer: { type: "uniform" } },
      storage(1, V | F),
      storage(2, F),
      storage(3, V | F),
      storage(4, F),
      storage(5, V | F),
      storage(6, V | F),
      storage(7, F),
      storage(8, F),
      { binding: 9, visibility: F, texture: { sampleType: "float", viewDimension: "2d-array" } },
      { binding: 10, visibility: F, sampler: { type: "filtering" } },
      { binding: 11, visibility: F, texture: { sampleType: "unfilterable-float", viewDimension: "2d-array" } },
    ],
  });
  k.maskLayout = device.createBindGroupLayout({
    entries: [{ binding: 0, visibility: V | F, buffer: { type: "uniform" } }, storage(7, F), storage(8, F)],
  });
  k.downLayout = device.createBindGroupLayout({ entries: [{ binding: 0, visibility: F, texture: { sampleType: "float" } }] });
  k.sampler = device.createSampler({ minFilter: "linear", magFilter: "linear", mipmapFilter: "linear", addressModeU: "clamp-to-edge", addressModeV: "clamp-to-edge" });
  k.layout1 = device.createBindGroupLayout({ entries: [{ binding: 0, visibility: F, texture: { sampleType: "unfilterable-float" } }] });
  const module = device.createShaderModule({ code: engine.recShader() });
  void module.getCompilationInfo().then((info) => {
    for (const msg of info.messages) if (msg.type === "error") console.error(`records wgsl ${msg.lineNum}:${msg.linePos} ${msg.message}`);
  });
  k.pipeline = device.createRenderPipeline({
    layout: device.createPipelineLayout({ bindGroupLayouts: [k.layout0, k.layout1] }),
    vertex: { module, entryPoint: "vs" },
    fragment: {
      module,
      entryPoint: "fs",
      targets: [{ format: TARGET_FORMAT, blend: { color: { srcFactor: "one", dstFactor: "one-minus-src-alpha", operation: "add" }, alpha: { srcFactor: "one", dstFactor: "one-minus-src-alpha", operation: "add" } } }],
    },
    primitive: { topology: "triangle-strip" },
  });
  k.maskPipeline = device.createRenderPipeline({
    layout: device.createPipelineLayout({ bindGroupLayouts: [k.maskLayout] }),
    vertex: { module, entryPoint: "mask_vs" },
    fragment: { module, entryPoint: "mask_fs", targets: [{ format: "r8unorm" }] },
    primitive: { topology: "triangle-list" },
  });
  const down = device.createShaderModule({ code: DOWN_WGSL });
  k.downPipeline = device.createRenderPipeline({
    layout: device.createPipelineLayout({ bindGroupLayouts: [k.downLayout] }),
    vertex: { module: down, entryPoint: "vs" },
    fragment: { module: down, entryPoint: "fs", targets: [{ format: "r8unorm" }] },
    primitive: { topology: "triangle-list" },
  });
  const dummy = device.createTexture({ size: [1, 1], format: "rgba8unorm", usage: GPUTextureUsage.TEXTURE_BINDING });
  k.dummyGroup = device.createBindGroup({ layout: k.layout1, entries: [{ binding: 0, resource: dummy.createView() }] });
  kits.set(device, k);
  return k;
}
