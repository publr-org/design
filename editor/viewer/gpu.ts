// The GPU canvas: PublrEngine's frame (a flat list of primitives the engine writes into
// its memory, docs/gpu.md) drawn with WebGPU.
//
// Per frame: the engine walks the scene for the view; the path atlas is filled by stencil
// and cover (4x MSAA at twice the resolution); then the draws run in order: primitives
// into the current target (batched as the engine grouped them), surfaces begun and ended
// (offscreen targets for group opacity, blend modes, masks, patterns and effects), and
// effect passes (compute) on surfaces. A surface whose pixels depend only on its own draws
// is kept for later frames under the key the engine gave it, and skipped while kept. The
// target goes onto the canvas. What the GPU does not draw (a tool's snapped glyphs) comes
// from the CPU: the render workers draw it in 512-pixel layer tiles, cached per node and
// scale, composited where the engine put it in the draw order.
//
// This is glue, not UI: buffers, textures, pipelines and the frame loop.

import type { Engine } from "./engine";
import { feedOf } from "./feed";
import type { Pool, Slot } from "./pool";

const NONE = 0xffffffff;
const SURFACE_BIT = 0x80000000;
const PRIM_WORDS = 16;
const SHAPE_WORDS = 32;
const PAINT_WORDS = 16;
const FALLBACK_WORDS = 24;
const DRAW_WORDS = 8;
const SURFACE_WORDS = 16;
const PASS_WORDS = 32;
const ATLAS_SIZE = 2048;
/** Side of a CPU layer tile, in device pixels. */
const LAYER_TILE = 512;
const PAINT_TEXTURE = 7;
const FEATURE_FALLBACK = 6;
/** Bytes of one uniform slot (the dynamic offset's alignment). */
const SLOT = 256;
const TARGET_FORMAT: GPUTextureFormat = "rgba16float";

/** Header fields (u32 words), docs/gpu.md. */
const H = {
  version: 0,
  prims: 1,
  primCount: 2,
  shapes: 3,
  shapeCount: 4,
  paints: 5,
  paintCount: 6,
  stops: 7,
  stopCount: 8,
  draws: 9,
  drawCount: 10,
  entries: 11,
  entryCount: 12,
  layers: 13,
  layerCount: 14,
  verts: 15,
  vertCount: 16,
  textures: 17,
  textureCount: 18,
  fallbacks: 19,
  fallbackCount: 20,
  nodes: 21,
  culled: 22,
  features: 23,
  reasons: 35,
  glyphUploads: 47,
  glyphUploadCount: 48,
  glyphDraws: 49,
  glyphDrawCount: 50,
  glyphsCached: 51,
  glyphsDeferred: 52,
  surfaces: 53,
  surfaceCount: 54,
  passes: 55,
  passCount: 56,
  apron: 57,
  surfacePixels: 58,
} as const;
const HEADER_WORDS = 59;
const NO_READS: number[] = [];
/** New glyph masks a frame shown on the canvas rasterises at most (the engine's default). */
const GLYPH_BUDGET = 400;
/** A view whose frame takes longer than this to build (ms of this thread) is kept on
 * the GPU and patched (`drawKept`) rather than built each frame. */
const COSTLY_MS = 10;
/** A kept view whose squares took the engine less than this in all (ms, scaled to the
 * canvas) may be cheap: the next frame is built whole to see (`drawPage` measures it). */
const MAYBE_CHEAP_MS = 40;
/** What a kept view holds around the canvas, device pixels (panning shows it at once). */
const KEPT_MARGIN = 256;
/** Side of the squares a kept view is built in, device pixels: small enough that one
 * square with every glyph mask new (a new scale) stays well under a frame. */
const KEPT_TILE = 256;
/** Building a kept view takes at most this much of a frame, ms (at least one square). */
const KEPT_BUILD_MS = 12;
const LAYER_WORDS = 8;
const GLYPH_ATLAS = 4096;
/** Up to this many new glyph masks a frame are uploaded one by one (more: by rows). */
const GLYPH_UPLOADS_ONE_BY_ONE = 256;

const DRAW_PRIMS = 0;
const DRAW_FALLBACK = 1;
const DRAW_BEGIN = 2;
const DRAW_END = 3;
const DRAW_PASS = 4;
const FLAG_BACKDROP = 1;
const FLAG_MAX = 2;
const FLAG_ERASE = 4;

const PASS_GAUSS = 1;
const PASS_BOX3 = 2;
const PASS_PROGRESSIVE = 3;
const PASS_SPREAD = 4;
const PASS_NOISE = 5;
const PASS_TEXTURE = 6;
const PASS_BACKDROP = 7;

export const FEATURES = ["", "fill formula", "fill path", "stroke ring", "stroke path", "text", "fallback", "layer", "shadow formula", "shadow pass"];
export const REASONS = ["", "text", "effect", "blend", "opacity", "pattern", "paint blend", "clip path", "drop shadow", "inner shadow", "mask"];

/** A frame's numbers, for the HUD and the checks. */
export type GpuStats = {
  /** Building the scene in the engine, ms. */
  sceneMs: number;
  /** Encoding and submitting, ms. */
  encodeMs: number;
  /** Until the GPU finished the frame (measured after it did), ms. */
  gpuMs: number;
  drawCalls: number;
  prims: number;
  pathEntries: number;
  atlasLayers: number;
  /** Glyph masks added into the path atlas this frame, new ones rasterised, cached. */
  glyphs: number;
  glyphsNew: number;
  glyphsCached: number;
  nodes: number;
  fallbacks: number;
  /** Fallback layer tiles still on their way. */
  pending: number;
  /** Text styles drawn as paths for want of glyph masks (more come next frame). */
  glyphsDeferred: number;
  /** Surfaces this frame, those drawn (the rest were kept), effect passes run. */
  surfaces: number;
  surfacesDrawn: number;
  passes: number;
  features: Record<string, number>;
  reasons: Record<string, number>;
  /** Bytes of GPU textures this canvas holds (images, layers, atlas, targets). */
  textureBytes: number;
  /** Of which kept surfaces. */
  keptBytes: number;
};

type LayerTile = {
  key: string;
  base: string;
  ctmKey: string;
  ctm: number[];
  /** Top space of the ctm it was drawn at: x0, y0, x1, y1. */
  rect: number[];
  texture: GPUTexture;
  bytes: number;
  used: number;
  made: number;
};

type LayerJob = { page: number; key: string; base: string; ctmKey: string; id: string; part: number; child: number; ctm: number[]; rect: number[]; dist: number; gen: number };

type ImageTex = { texture: GPUTexture; view: GPUTextureView; bytes: number; used: number };

/** A surface kept between frames. */
type Kept = { key: string; texture: GPUTexture; bytes: number; used: number };

/** One fallback of the current frame, as the engine wrote it. */
type Fallback = { id: string; part: number; child: number; reason: number; prim: number; rev: number; ctm: number[]; rect: number[]; full: number[] };

/** A render target of the frame: the frame's own, or a surface. */
/** A view kept on the GPU between frames (`drawKept`): its texture holds device pixels
 * `x0`..`x0 + w`, `y0`..`y0 + h` of page `page` at `scale`. `todo` are the rects of it
 * not built yet (absolute device pixels, the nearest the view first; what is there
 * meanwhile is a stand-in), `again` rects built while images were on their way. */
type KeptView = {
  texture: GPUTexture;
  page: number;
  gen: number;
  scale: number;
  x0: number;
  y0: number;
  w: number;
  h: number;
  todo: number[][];
  again: number[][];
  /** The engine's time building it so far, ms, and whether it was built whole here (not
   * copied from another): then the time tells whether the view may be cheap. */
  ms: number;
  fresh: boolean;
};

/** A texture the frame draws into: its open render pass's ops (null: none open) and the
 * surfaces those ops read. */
type Target = { texture: GPUTexture; w: number; h: number; cleared: boolean; ops: ((p: GPURenderPassEncoder) => void)[] | null; reads: Set<number> };

const f32 = new Float32Array(1);
/** A number as the f32 the engine holds, as a stable string. */
const f32Key = (v: number) => {
  f32[0] = v;
  return String(f32[0]);
};

function invert(m: number[]): number[] | null {
  const det = m[0] * m[3] - m[1] * m[2];
  if (Math.abs(det) < 1e-12) return null;
  const id = 1 / det;
  return [m[3] * id, -m[1] * id, -m[2] * id, m[0] * id, (m[2] * m[5] - m[3] * m[4]) * id, (m[1] * m[4] - m[0] * m[5]) * id];
}

/** `a` after `b`. */
function mul(a: number[], b: number[]): number[] {
  return [
    a[0] * b[0] + a[2] * b[1],
    a[1] * b[0] + a[3] * b[1],
    a[0] * b[2] + a[2] * b[3],
    a[1] * b[2] + a[3] * b[3],
    a[0] * b[4] + a[2] * b[5] + a[4],
    a[1] * b[4] + a[3] * b[5] + a[5],
  ];
}

function apply(m: number[], x: number, y: number): [number, number] {
  return [m[0] * x + m[2] * y + m[4], m[1] * x + m[3] * y + m[5]];
}

/** Where rects `a` and `b` (x0, y0, x1, y1) overlap, or null. */
function intersect(a: number[], b: number[]): number[] | null {
  const r = [Math.max(a[0], b[0]), Math.max(a[1], b[1]), Math.min(a[2], b[2]), Math.min(a[3], b[3])];
  return r[2] > r[0] && r[3] > r[1] ? r : null;
}

/** Rect `a` less rect `b`, as up to four rects. */
function subtract(a: number[], b: number[]): number[][] {
  const c = intersect(a, b);
  if (!c) return [a];
  const out: number[][] = [];
  if (c[1] > a[1]) out.push([a[0], a[1], a[2], c[1]]);
  if (c[3] < a[3]) out.push([a[0], c[3], a[2], a[3]]);
  if (c[0] > a[0]) out.push([a[0], c[1], c[0], c[3]]);
  if (c[2] < a[2]) out.push([c[2], c[1], a[2], c[3]]);
  return out;
}

/** IEEE half to number. */
function half(h: number): number {
  const s = h & 0x8000 ? -1 : 1;
  const e = (h >> 10) & 0x1f;
  const f = h & 0x3ff;
  if (e === 0) return s * f * 2 ** -24;
  if (e === 31) return f ? NaN : s * Infinity;
  return s * (1 + f / 1024) * 2 ** (e - 15);
}

/** Uniform slots written while a frame is encoded, uploaded before it is submitted. */
class Slots {
  data = new ArrayBuffer(SLOT * 64);
  used = 0;

  reset(): void {
    this.used = 0;
  }

  /** A fresh slot: its byte offset and views over it. */
  take(): { offset: number; u32: Uint32Array; i32: Int32Array; f32: Float32Array } {
    if ((this.used + 1) * SLOT > this.data.byteLength) {
      const bigger = new ArrayBuffer(this.data.byteLength * 2);
      new Uint8Array(bigger).set(new Uint8Array(this.data));
      this.data = bigger;
    }
    const offset = this.used * SLOT;
    this.used++;
    new Uint8Array(this.data, offset, SLOT).fill(0);
    return { offset, u32: new Uint32Array(this.data, offset, SLOT / 4), i32: new Int32Array(this.data, offset, SLOT / 4), f32: new Float32Array(this.data, offset, SLOT / 4) };
  }
}

export class GpuCanvas {
  readonly device: GPUDevice;
  readonly canvas: HTMLCanvasElement;
  private context: GPUCanvasContext;
  private format: GPUTextureFormat;
  private maxDim: number;
  private g0Layout: GPUBindGroupLayout;
  private g1Layout: GPUBindGroupLayout;
  private atlasLayout: GPUBindGroupLayout;
  private presentLayout: GPUBindGroupLayout;
  private fxLayout: GPUBindGroupLayout;
  /** Prims by how they composite: over, replace (blend modes), max, erase. */
  private paintPipelines: Record<"over" | "replace" | "max" | "erase", GPURenderPipeline>;
  private stencilPipeline: GPURenderPipeline;
  private coverPipelines: GPURenderPipeline[];
  private presentPipeline: GPURenderPipeline;
  private glyphPipeline: GPURenderPipeline;
  private fxPipelines: Record<string, GPUComputePipeline>;
  private glyphAtlas: GPUTexture;
  /** What the glyph atlas holds, here: a frame with many new masks uploads the rows they
   * touch whole, with the masks already there. */
  private glyphCopy = new Uint8Array(GLYPH_ATLAS * GLYPH_ATLAS);
  private layerBuf: GPUBuffer;
  private atlasGroup: GPUBindGroup;
  private bufs = new Map<string, GPUBuffer>();
  private atlas: GPUTexture | null = null;
  private atlasViews: GPUTextureView[] = [];
  private msaaColor: GPUTexture;
  private msaaStencil: GPUTexture;
  private target: GPUTexture | null = null;
  private dummy: GPUTexture;
  private dummyView: GPUTextureView;
  private dummyGroup: GPUBindGroup;
  private backdropTex: GPUTexture | null = null;
  /** Textures and buffers to destroy once the frame using them is submitted. */
  private doomed: GPUTexture[] = [];
  private doomedBufs: GPUBuffer[] = [];
  private images = new Map<string, ImageTex>();
  private layers = new Map<string, LayerTile>();
  private layerBytes = 0;
  /** Layer tiles by node part (`base`), for stand-ins. */
  private byBase = new Map<string, Set<string>>();
  private inflight = new Map<string, LayerJob>();
  private queue: LayerJob[] = [];
  private frameNo = 0;
  /** Surface textures free for reuse, by size. */
  private free = new Map<string, GPUTexture[]>();
  private freeBytes = 0;
  /** Surfaces kept between frames, by key. */
  private kept = new Map<string, Kept>();
  private keptBytes = 0;
  private slots = new Slots();
  private slotBuf: GPUBuffer;
  private scaledPipeline: GPURenderPipeline;
  private fillPipeline: GPURenderPipeline;
  /** The view kept for costly frames, and the whole one standing in while it builds. */
  private keptView: KeptView | null = null;
  private standIn: KeptView | null = null;
  /** What the canvas target holds after `drawPage`, when it can become the kept view. */
  private targetView: { page: number; gen: number; scale: number; x0: number; y0: number; apron: number; whole: boolean } | null = null;
  /** Rects edits changed (page, x0, y0, x1, y1 in page units) the kept views rebuild. */
  private damaged: number[][] = [];
  /** The view is costly to build: the stage draws it with `drawKept`. */
  costly = false;
  /** Costly views are kept (`drawKept`) rather than built each frame. */
  keepViews = true;
  /** Bumped when the document changes: layers of older ones are dropped. */
  gen = 0;
  pool: Pool | null = null;
  /** Called when something arrives that the next frame should show. */
  onChange: () => void = () => {};
  stats: GpuStats = GpuCanvas.emptyStats();
  /** Cap on cached CPU layer tiles, bytes. */
  layerCap = 512 * 1048576;
  /** Cap on kept surfaces, bytes. */
  keptCap = 256 * 1048576;
  /** Reuse surface textures (debugging). */
  pooling = true;
  /** Keep surfaces between frames (off: every frame draws them all, to measure). */
  keep = true;
  /** Every layer tile drawn, with its time (ms) and size. */
  layerTimings: { ms: number; w: number; h: number }[] = [];

  static emptyStats(): GpuStats {
    return { sceneMs: 0, encodeMs: 0, gpuMs: 0, drawCalls: 0, prims: 0, pathEntries: 0, atlasLayers: 0, glyphs: 0, glyphsNew: 0, glyphsCached: 0, glyphsDeferred: 0, nodes: 0, fallbacks: 0, pending: 0, surfaces: 0, surfacesDrawn: 0, passes: 0, features: {}, reasons: {}, textureBytes: 0, keptBytes: 0 };
  }

  /** A GPU canvas drawing into `canvas`, or null when the browser has no WebGPU. */
  static async create(canvas: HTMLCanvasElement, engine: Engine): Promise<GpuCanvas | null> {
    const gpu = (navigator as Navigator & { gpu?: GPU }).gpu;
    if (!gpu) return null;
    const adapter = await gpu.requestAdapter({ powerPreference: "high-performance" });
    if (!adapter) return null;
    const device = await adapter.requestDevice({
      requiredLimits: {
        maxTextureDimension2D: adapter.limits.maxTextureDimension2D,
        maxTextureArrayLayers: adapter.limits.maxTextureArrayLayers,
        maxStorageBufferBindingSize: adapter.limits.maxStorageBufferBindingSize,
        maxBufferSize: adapter.limits.maxBufferSize,
      },
    });
    device.lost.then((info) => console.error("gpu: device lost", info.message));
    device.addEventListener("uncapturederror", (e) => console.error("gpu:", (e as GPUUncapturedErrorEvent).error.message));
    return new GpuCanvas(device, canvas, gpu.getPreferredCanvasFormat(), engine);
  }

  private constructor(device: GPUDevice, canvas: HTMLCanvasElement, format: GPUTextureFormat, engine: Engine) {
    this.device = device;
    this.canvas = canvas;
    this.format = format;
    this.maxDim = device.limits.maxTextureDimension2D;
    const context = canvas.getContext("webgpu");
    if (!context) throw new Error("gpu: no webgpu context");
    this.context = context;
    context.configure({ device, format, alphaMode: "opaque" });

    const F = GPUShaderStage.FRAGMENT;
    const V = GPUShaderStage.VERTEX;
    const C = GPUShaderStage.COMPUTE;
    this.g0Layout = device.createBindGroupLayout({
      entries: [
        { binding: 0, visibility: V | F, buffer: { type: "uniform", hasDynamicOffset: true, minBindingSize: 16 } },
        { binding: 1, visibility: V | F, buffer: { type: "read-only-storage" } },
        { binding: 2, visibility: F, buffer: { type: "read-only-storage" } },
        { binding: 3, visibility: F, buffer: { type: "read-only-storage" } },
        { binding: 4, visibility: F, buffer: { type: "read-only-storage" } },
        { binding: 5, visibility: F, texture: { sampleType: "float", viewDimension: "2d-array" } },
      ],
    });
    this.g1Layout = device.createBindGroupLayout({
      entries: [
        { binding: 0, visibility: F, texture: { sampleType: "unfilterable-float" } },
        { binding: 1, visibility: F, texture: { sampleType: "unfilterable-float" } },
        { binding: 2, visibility: F, texture: { sampleType: "unfilterable-float" } },
      ],
    });
    this.atlasLayout = device.createBindGroupLayout({
      entries: [
        { binding: 0, visibility: V, buffer: { type: "uniform" } },
        { binding: 1, visibility: F, texture: { sampleType: "float" } },
      ],
    });
    this.presentLayout = device.createBindGroupLayout({
      entries: [
        { binding: 0, visibility: F, texture: { sampleType: "unfilterable-float" } },
        { binding: 1, visibility: F, buffer: { type: "uniform" } },
      ],
    });
    this.fxLayout = device.createBindGroupLayout({
      entries: [
        { binding: 0, visibility: C, buffer: { type: "uniform", hasDynamicOffset: true, minBindingSize: 144 } },
        { binding: 1, visibility: C, texture: { sampleType: "unfilterable-float" } },
        { binding: 2, visibility: C, storageTexture: { access: "write-only", format: TARGET_FORMAT } },
      ],
    });

    const paint = device.createShaderModule({ code: engine.gpuShader(0) });
    const atlas = device.createShaderModule({ code: engine.gpuShader(1) });
    const present = device.createShaderModule({ code: engine.gpuShader(2) });
    const fx = device.createShaderModule({ code: engine.gpuShader(3) });
    for (const mod of [paint, atlas, present, fx]) {
      void mod.getCompilationInfo().then((info) => {
        for (const msg of info.messages) if (msg.type === "error") console.error(`wgsl ${msg.lineNum}:${msg.linePos} ${msg.message}`);
      });
    }

    const blendOf = (op: GPUBlendOperation, src: GPUBlendFactor, dst: GPUBlendFactor): GPUBlendState => ({
      color: { srcFactor: src, dstFactor: dst, operation: op },
      alpha: { srcFactor: src, dstFactor: dst, operation: op },
    });
    const paintLayout = device.createPipelineLayout({ bindGroupLayouts: [this.g0Layout, this.g1Layout] });
    const paintPipeline = (blend: GPUBlendState | undefined) =>
      device.createRenderPipeline({
        layout: paintLayout,
        vertex: { module: paint, entryPoint: "vs" },
        fragment: { module: paint, entryPoint: "fs", targets: [{ format: TARGET_FORMAT, blend }] },
        primitive: { topology: "triangle-strip" },
      });
    this.paintPipelines = {
      over: paintPipeline(blendOf("add", "one", "one-minus-src-alpha")),
      replace: paintPipeline(undefined),
      max: paintPipeline(blendOf("max", "one", "one")),
      erase: paintPipeline(blendOf("add", "zero", "one-minus-src-alpha")),
    };
    const atlasPipelineLayout = device.createPipelineLayout({ bindGroupLayouts: [this.atlasLayout] });
    this.stencilPipeline = device.createRenderPipeline({
      layout: atlasPipelineLayout,
      vertex: { module: atlas, entryPoint: "stencil_vs", buffers: [{ arrayStride: 8, attributes: [{ format: "float32x2", offset: 0, shaderLocation: 0 }] }] },
      fragment: { module: atlas, entryPoint: "stencil_fs", targets: [{ format: "r8unorm", writeMask: 0 }] },
      primitive: { topology: "triangle-list", cullMode: "none" },
      depthStencil: {
        format: "stencil8",
        depthWriteEnabled: false,
        depthCompare: "always",
        stencilFront: { compare: "always", passOp: "increment-wrap" },
        stencilBack: { compare: "always", passOp: "decrement-wrap" },
      },
      multisample: { count: 4 },
    });
    this.coverPipelines = [0xff, 0x01].map((readMask) =>
      device.createRenderPipeline({
        layout: atlasPipelineLayout,
        vertex: { module: atlas, entryPoint: "cover_vs", buffers: [{ arrayStride: 16, stepMode: "instance", attributes: [{ format: "uint32x4", offset: 0, shaderLocation: 0 }] }] },
        fragment: { module: atlas, entryPoint: "cover_fs", targets: [{ format: "r8unorm" }] },
        primitive: { topology: "triangle-strip" },
        depthStencil: {
          format: "stencil8",
          depthWriteEnabled: false,
          depthCompare: "always",
          stencilFront: { compare: "not-equal", failOp: "keep", passOp: "zero" },
          stencilBack: { compare: "not-equal", failOp: "keep", passOp: "zero" },
          stencilReadMask: readMask,
        },
        multisample: { count: 4 },
      }),
    );
    this.glyphPipeline = device.createRenderPipeline({
      layout: atlasPipelineLayout,
      vertex: {
        module: atlas,
        entryPoint: "glyph_vs",
        buffers: [
          {
            arrayStride: 32,
            stepMode: "instance",
            attributes: [
              { format: "uint32x4", offset: 0, shaderLocation: 0 },
              { format: "uint32x4", offset: 16, shaderLocation: 1 },
            ],
          },
        ],
      },
      fragment: {
        module: atlas,
        entryPoint: "glyph_fs",
        targets: [{ format: "r8unorm", blend: blendOf("add", "one", "one") }],
      },
      primitive: { topology: "triangle-strip" },
    });
    this.presentPipeline = device.createRenderPipeline({
      layout: device.createPipelineLayout({ bindGroupLayouts: [this.presentLayout] }),
      vertex: { module: present, entryPoint: "vs" },
      fragment: { module: present, entryPoint: "fs", targets: [{ format }] },
      primitive: { topology: "triangle-list" },
    });
    const scaled = device.createShaderModule({ code: engine.gpuShader(4) });
    this.scaledPipeline = device.createRenderPipeline({
      layout: device.createPipelineLayout({ bindGroupLayouts: [this.presentLayout] }),
      vertex: { module: scaled, entryPoint: "vs" },
      fragment: { module: scaled, entryPoint: "fs", targets: [{ format }] },
      primitive: { topology: "triangle-list" },
    });
    this.fillPipeline = device.createRenderPipeline({
      layout: device.createPipelineLayout({ bindGroupLayouts: [this.presentLayout] }),
      vertex: { module: scaled, entryPoint: "vs" },
      fragment: { module: scaled, entryPoint: "fs", targets: [{ format: TARGET_FORMAT }] },
      primitive: { topology: "triangle-list" },
    });
    const fxPipelineLayout = device.createPipelineLayout({ bindGroupLayouts: [this.fxLayout] });
    this.fxPipelines = {};
    for (const entry of ["gauss", "box", "progressive", "spread", "noise", "texture", "backdrop"]) {
      this.fxPipelines[entry] = device.createComputePipeline({ layout: fxPipelineLayout, compute: { module: fx, entryPoint: entry } });
    }

    this.slotBuf = device.createBuffer({ size: SLOT * 64, usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST });
    this.layerBuf = device.createBuffer({ size: 16, usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST });
    device.queue.writeBuffer(this.layerBuf, 0, new Float32Array([ATLAS_SIZE, ATLAS_SIZE, 0, 0]));
    this.glyphAtlas = device.createTexture({ size: [GLYPH_ATLAS, GLYPH_ATLAS], format: "r8unorm", usage: GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.COPY_DST });
    this.atlasGroup = device.createBindGroup({
      layout: this.atlasLayout,
      entries: [
        { binding: 0, resource: { buffer: this.layerBuf } },
        { binding: 1, resource: this.glyphAtlas.createView() },
      ],
    });
    this.msaaColor = device.createTexture({ size: [ATLAS_SIZE, ATLAS_SIZE], format: "r8unorm", sampleCount: 4, usage: GPUTextureUsage.RENDER_ATTACHMENT });
    this.msaaStencil = device.createTexture({ size: [ATLAS_SIZE, ATLAS_SIZE], format: "stencil8", sampleCount: 4, usage: GPUTextureUsage.RENDER_ATTACHMENT });
    this.dummy = device.createTexture({ size: [1, 1], format: "rgba8unorm", usage: GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.COPY_DST });
    this.dummyView = this.dummy.createView();
    this.dummyGroup = this.group1(this.dummyView, null, null);
    this.ensureAtlas(1);
  }

  // ------------------------------------------------------------------ resources

  private buffer(name: string, bytes: number, usage: number): GPUBuffer {
    let b = this.bufs.get(name);
    if (!b || b.size < bytes) {
      b?.destroy();
      let size = 4096;
      while (size < bytes) size *= 2;
      b = this.device.createBuffer({ size, usage: usage | GPUBufferUsage.COPY_DST });
      this.bufs.set(name, b);
    }
    return b;
  }

  private group1(tex: GPUTextureView, backdrop: GPUTextureView | null, mask: GPUTextureView | null): GPUBindGroup {
    return this.device.createBindGroup({
      layout: this.g1Layout,
      entries: [
        { binding: 0, resource: tex },
        { binding: 1, resource: backdrop ?? this.dummyView },
        { binding: 2, resource: mask ?? this.dummyView },
      ],
    });
  }

  private ensureAtlas(layers: number): void {
    if (this.atlas && this.atlas.depthOrArrayLayers >= layers) return;
    this.atlas?.destroy();
    const n = Math.max(layers, this.atlas ? this.atlas.depthOrArrayLayers : 1);
    this.atlas = this.device.createTexture({
      size: [ATLAS_SIZE, ATLAS_SIZE, n],
      format: "r8unorm",
      usage: GPUTextureUsage.RENDER_ATTACHMENT | GPUTextureUsage.TEXTURE_BINDING,
    });
    this.atlasViews = [];
    for (let i = 0; i < n; i++) this.atlasViews.push(this.atlas.createView({ dimension: "2d", baseArrayLayer: i, arrayLayerCount: 1 }));
  }

  private ensureTarget(w: number, h: number): GPUTexture {
    if (!this.target || this.target.width !== w || this.target.height !== h) {
      this.target?.destroy();
      this.target = this.device.createTexture({
        size: [w, h],
        format: TARGET_FORMAT,
        // Copied into once it becomes the kept view (`drawKept`).
        usage: GPUTextureUsage.RENDER_ATTACHMENT | GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.COPY_SRC | GPUTextureUsage.COPY_DST,
      });
    }
    return this.target;
  }

  /** A surface texture of at least `w` x `h` (reused when one is free): sizes go up in
   * steps, so surfaces that change size as the view zooms reuse the same textures. What
   * lies past `w` x `h` stays clear (the first pass clears the whole texture). */
  private acquire(w0: number, h0: number): GPUTexture {
    const step = (v: number) => (v <= 1024 ? Math.ceil(v / 64) * 64 : Math.ceil(v / 256) * 256);
    const w = Math.min(this.maxDim, step(w0));
    const h = Math.min(this.maxDim, step(h0));
    const key = `${w}x${h}`;
    const list = this.pooling ? this.free.get(key) : undefined;
    const t = list?.pop();
    if (t) {
      this.freeBytes -= w * h * 8;
      return t;
    }
    return this.device.createTexture({
      size: [w, h],
      format: TARGET_FORMAT,
      usage: GPUTextureUsage.RENDER_ATTACHMENT | GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.STORAGE_BINDING | GPUTextureUsage.COPY_SRC | GPUTextureUsage.COPY_DST,
    });
  }

  private release(t: GPUTexture): void {
    const key = `${t.width}x${t.height}`;
    let list = this.free.get(key);
    if (!list) this.free.set(key, (list = []));
    if (list.includes(t)) {
      console.error("gpu: a surface texture released twice");
      return;
    }
    list.push(t);
    this.freeBytes += t.width * t.height * 8;
  }

  /** Gives back free surface textures past a budget. */
  private trimFree(): void {
    const cap = 128 * 1048576;
    if (this.freeBytes <= cap) return;
    for (const [key, list] of this.free) {
      while (list.length && this.freeBytes > cap / 2) {
        const t = list.pop()!;
        this.freeBytes -= t.width * t.height * 8;
        t.destroy();
      }
      if (!list.length) this.free.delete(key);
    }
  }

  private backdropFor(w: number, h: number): GPUTexture {
    const t = this.backdropTex;
    if (t && t.width >= w && t.height >= h) return t;
    // The old one may be in this frame's commands: destroyed after it is submitted.
    if (t) this.doomed.push(t);
    this.backdropTex = this.device.createTexture({
      size: [Math.max(w, t?.width ?? 0, 256), Math.max(h, t?.height ?? 0, 256)],
      format: TARGET_FORMAT,
      usage: GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.COPY_DST,
    });
    return this.backdropTex;
  }

  /** The texture of image `index` of the frame (made once per image). */
  private image(engine: Engine, rec: Uint32Array, index: number): ImageTex {
    const o = index * 8;
    // By hash and size: an image decoded more finely later (zoomed in) is a new texture.
    const hash = `${engine.string(rec[o], rec[o + 1])}@${rec[o + 2]}`;
    let img = this.images.get(hash);
    if (img) {
      img.used = this.frameNo;
      return img;
    }
    const levels = rec[o + 4];
    let base = 0;
    while (base < levels - 1 && (rec[o + 2] >> base > this.maxDim || rec[o + 3] >> base > this.maxDim)) base++;
    const l0 = engine.gpuTextureLevel(index, base);
    const texture = this.device.createTexture({
      size: [l0.width, l0.height],
      format: "rgba8unorm",
      mipLevelCount: levels - base,
      usage: GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.COPY_DST,
    });
    let bytes = 0;
    for (let l = base; l < levels; l++) {
      const lv = engine.gpuTextureLevel(index, l);
      const data = new Uint8Array(engine.memory.buffer, lv.ptr, lv.width * lv.height * 4);
      this.device.queue.writeTexture({ texture, mipLevel: l - base }, data, { bytesPerRow: lv.width * 4 }, [lv.width, lv.height]);
      bytes += data.length;
    }
    img = { texture, view: texture.createView(), bytes, used: this.frameNo };
    this.images.set(hash, img);
    return img;
  }

  /** The page the last frame drew (its layers are asked of the workers on that page). */
  private shownPage = 0;

  // ------------------------------------------------------------------ per document

  /** The engine (one per open document) whose caches are the ones in place, and the
   * caches of the others kept open, least recently shown first. */
  private owner: Engine | null = null;
  private parked = new Map<Engine, Record<string, unknown>>();
  /** Documents whose caches are kept besides the one shown. */
  keepOthers = 3;
  private static readonly PER_DOC = ["glyphAtlas", "glyphCopy", "atlasGroup", "layers", "layerBytes", "byBase", "inflight", "queue", "kept", "keptBytes", "keptView", "standIn", "targetView", "damaged", "costly", "gen"] as const;

  /** Draws `engine`'s document from now on: its glyph atlas, kept surfaces, CPU layers and
   * kept view come back as they were when it last showed (fresh ones when new), the
   * other document's are kept for when it shows again. Past `keepOthers`, the document
   * shown longest ago gives its caches up (and its engine forgets what it kept of them). */
  useEngine(engine: Engine): void {
    if (this.owner === engine) return;
    const self = this as unknown as Record<string, unknown>;
    if (this.owner) {
      const saved: Record<string, unknown> = {};
      for (const k of GpuCanvas.PER_DOC) saved[k] = self[k];
      // Parked, a document keeps a smaller share of kept surfaces (the shown one's cap).
      const kept = saved.kept as Map<string, Kept>;
      let bytes = saved.keptBytes as number;
      const cap = 64 * 1048576;
      if (bytes > cap) {
        for (const k of [...kept.values()].sort((a, b) => a.used - b.used)) {
          if (bytes <= cap) break;
          kept.delete(k.key);
          bytes -= k.bytes;
          this.release(k.texture);
        }
        saved.keptBytes = bytes;
      }
      this.parked.delete(this.owner);
      this.parked.set(this.owner, saved);
    }
    const back = this.parked.get(engine);
    if (back) {
      this.parked.delete(engine);
      for (const k of GpuCanvas.PER_DOC) self[k] = back[k];
    } else {
      this.freshCaches();
      // What the engine kept refers to another atlas's places.
      engine.gpuForget();
    }
    this.owner = engine;
    while (this.parked.size > this.keepOthers) {
      const [old, saved] = this.parked.entries().next().value as [Engine, Record<string, unknown>];
      this.parked.delete(old);
      (saved.glyphAtlas as GPUTexture).destroy();
      for (const t of (saved.layers as Map<string, LayerTile>).values()) t.texture.destroy();
      for (const k of (saved.kept as Map<string, Kept>).values()) this.release(k.texture);
      for (const v of [saved.keptView, saved.standIn] as (KeptView | null)[]) if (v) this.doomed.push(v.texture);
      old.gpuForget();
    }
    this.onEngine(engine);
  }

  /** Called when the document drawn changes (the records canvas follows). */
  onEngine: (engine: Engine) => void = () => {};

  /** A glyph atlas and empty caches for a document new here. */
  private freshCaches(): void {
    this.glyphAtlas = this.device.createTexture({ size: [GLYPH_ATLAS, GLYPH_ATLAS], format: "r8unorm", usage: GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.COPY_DST });
    this.glyphCopy = new Uint8Array(GLYPH_ATLAS * GLYPH_ATLAS);
    this.atlasGroup = this.device.createBindGroup({
      layout: this.atlasLayout,
      entries: [
        { binding: 0, resource: { buffer: this.layerBuf } },
        { binding: 1, resource: this.glyphAtlas.createView() },
      ],
    });
    this.layers = new Map();
    this.layerBytes = 0;
    this.byBase = new Map();
    this.inflight = new Map();
    this.queue = [];
    this.kept = new Map();
    this.keptBytes = 0;
    this.keptView = null;
    this.standIn = null;
    this.targetView = null;
    this.damaged = [];
    this.costly = false;
  }

  /** Called by `clear` (the records canvas forgets its own). */
  onClear: () => void = () => {};

  /** Forgets every image, layer and kept surface (the document changed). */
  clear(): void {
    this.onClear();
    // The files kept open let theirs go too (fonts changed, or every file closed).
    for (const [old, saved] of this.parked) {
      (saved.glyphAtlas as GPUTexture).destroy();
      for (const t of (saved.layers as Map<string, LayerTile>).values()) t.texture.destroy();
      for (const k of (saved.kept as Map<string, Kept>).values()) this.release(k.texture);
      for (const v of [saved.keptView, saved.standIn] as (KeptView | null)[]) if (v) this.doomed.push(v.texture);
      old.gpuForget();
    }
    this.parked.clear();
    this.gen++;
    for (const i of this.images.values()) i.texture.destroy();
    this.images.clear();
    for (const t of this.layers.values()) t.texture.destroy();
    this.layers.clear();
    this.byBase.clear();
    this.layerBytes = 0;
    this.queue = [];
    for (const k of this.kept.values()) k.texture.destroy();
    this.kept.clear();
    this.keptBytes = 0;
    this.dropKept();
  }

  // ------------------------------------------------------------------ kept views

  /** Forgets the kept views (the next costly frame builds afresh). */
  dropKept(): void {
    if (this.keptView) this.doomed.push(this.keptView.texture);
    if (this.standIn && this.standIn !== this.keptView) this.doomed.push(this.standIn.texture);
    this.keptView = null;
    this.standIn = null;
    this.targetView = null;
    this.damaged = [];
  }

  /** Rects an edit changed: `[page, x0, y0, x1, y1]` in page units. Kept views build
   * them again. */
  damage(rects: number[][]): void {
    for (const r of rects) this.damaged.push(r);
  }

  /** Draws a view that is costly to build (`costly`) from the view kept on the GPU:
   * panning shows it moved by whole pixels and builds only the strips the view moves
   * into; a new scale shows the kept one scaled (`moving`: the zoom is changing; only
   * that) and builds the new one in squares, nearest the centre first, a few a frame, over
   * the stand-in; an edit builds the rects it damaged. A rect built alone is what a whole
   * frame draws there (the engine builds any rect on the view's device-pixel grid, as CPU
   * tiles are), so the kept view is the frame, pixel for pixel. `whole` says whether the
   * engine had everything the last build drew. True when the canvas shows the view
   * whole and exact. */
  drawKept(engine: Engine, page: number, x: number, y: number, scale: number, background: number[], whole: () => boolean, moving: boolean): boolean {
    this.shownPage = page;
    const s = Math.fround(scale);
    const vx = Math.round(x * s);
    const vy = Math.round(y * s);
    const cw = this.canvas.width;
    const ch = this.canvas.height;
    const bg = [background[0], background[1], background[2], 1];
    const mine = (k: KeptView | null): k is KeptView => !!k && k.page === page && k.gen === this.gen;
    if (this.keptView && !mine(this.keptView)) {
      if (this.keptView !== this.standIn) this.doomed.push(this.keptView.texture);
      this.keptView = null;
    }
    if (this.standIn && !mine(this.standIn)) {
      this.doomed.push(this.standIn.texture);
      this.standIn = null;
    }
    this.takeDamage();
    let k = this.keptView;
    if (moving) {
      // Only stand-ins while the zoom changes: the whole kept view, scaled.
      const src = k && !k.todo.length && !k.again.length ? k : (this.standIn ?? k);
      const encoder = this.device.createCommandEncoder();
      this.encodeScaled(encoder, src, vx, vy, s, bg, null);
      this.device.queue.submit([encoder.finish()]);
      this.afterSubmit();
      return false;
    }
    if (!k && this.targetView && this.target) {
      // The frame `drawPage` drew last (a page switch builds one): kept as it is, its
      // apron (drawn without what lies past it) built again.
      const t = this.targetView;
      if (t.whole && t.page === page && t.gen === this.gen && t.scale === s) {
        const w = this.target.width;
        const h = this.target.height;
        k = this.keptView = { texture: this.target, page, gen: this.gen, scale: s, x0: t.x0, y0: t.y0, w, h, todo: [], again: [], ms: 0, fresh: false };
        this.target = null;
        this.targetView = null;
        const a = t.apron;
        if (a > 0) k.todo.push([t.x0, t.y0, t.x0 + w, t.y0 + a], [t.x0, t.y0 + h - a, t.x0 + w, t.y0 + h], [t.x0, t.y0 + a, t.x0 + a, t.y0 + h - a], [t.x0 + w - a, t.y0 + a, t.x0 + w, t.y0 + h - a]);
      }
    }
    const view = [vx, vy, vx + cw, vy + ch];
    if (!k || k.scale !== s) {
      // A new scale (or none kept): the whole one there was stands in, scaled.
      const old = k && !k.todo.length && !k.again.length ? k : this.standIn;
      if (k && k !== old) this.doomed.push(k.texture);
      if (this.standIn && this.standIn !== old) this.doomed.push(this.standIn.texture);
      this.standIn = old;
      k = this.keptView = this.newKept(page, s, view, old, bg);
    } else if (view[0] < k.x0 || view[1] < k.y0 || view[2] > k.x0 + k.w || view[3] > k.y0 + k.h) {
      // Moved past what is kept: a new one around the view, what was built copied over.
      const n = this.newKept(page, s, view, k, bg);
      const covered = [Math.max(n.x0, k.x0), Math.max(n.y0, k.y0), Math.min(n.x0 + n.w, k.x0 + k.w), Math.min(n.y0 + n.h, k.y0 + k.h)];
      n.todo = subtract([n.x0, n.y0, n.x0 + n.w, n.y0 + n.h], covered);
      for (const r of [...k.todo, ...k.again]) {
        const c = intersect(r, [n.x0, n.y0, n.x0 + n.w, n.y0 + n.h]);
        if (c) n.todo.push(c);
      }
      n.fresh = false;
      if (this.standIn !== k) this.doomed.push(k.texture);
      k = this.keptView = n;
    }
    // What the view shows first.
    const cx = vx + cw / 2;
    const cy = vy + ch / 2;
    const dist = (r: number[]) => Math.hypot(Math.max(r[0] - cx, 0, cx - r[2]), Math.max(r[1] - cy, 0, cy - r[3]));
    k.todo.sort((a, b) => dist(a) - dist(b));
    // Rects built while images were on their way, again once they are in.
    const feed = feedOf(engine);
    if (k.again.length && !feed?.busy()) {
      k.todo.push(...k.again);
      k.again = [];
    }
    const t0 = performance.now();
    while (k.todo.length && performance.now() - t0 < KEPT_BUILD_MS) {
      const r = k.todo.shift()!;
      if (!this.buildRect(engine, page, s, r, k, bg, whole)) k.again.push(r);
      k.ms += this.stats.sceneMs;
    }
    if (!k.todo.length && !k.again.length) {
      // Whole: the stand-in goes; a view this quick to build is drawn each frame again.
      if (this.standIn && this.standIn !== k) this.doomed.push(this.standIn.texture);
      this.standIn = null;
      if (k.fresh && k.ms * ((cw * ch) / (k.w * k.h)) < MAYBE_CHEAP_MS) this.costly = false;
      k.ms = 0;
      k.fresh = false;
    }
    const encoder = this.device.createCommandEncoder();
    this.encodePresent(encoder, k.texture, vx - k.x0, vy - k.y0);
    this.device.queue.submit([encoder.finish()]);
    this.afterSubmit();
    const done = !k.todo.length && !k.again.length;
    this.lastComplete = done;
    return done;
  }

  /** The kept view has rects still to build (the stage draws again next frame). */
  keptBuilding(): boolean {
    return !!this.keptView && this.keptView.todo.length > 0;
  }

  /** The damage edits reported, as rects of the kept view to build again. */
  private takeDamage(): void {
    const k = this.keptView;
    const list = this.damaged;
    this.damaged = [];
    if (!k) return;
    const all = [k.x0, k.y0, k.x0 + k.w, k.y0 + k.h];
    for (const d of list) {
      if (d[0] !== k.page) continue;
      // Whole device pixels around it, and one more for antialiasing.
      const r = intersect([Math.floor(d[1] * k.scale) - 1, Math.floor(d[2] * k.scale) - 1, Math.ceil(d[3] * k.scale) + 1, Math.ceil(d[4] * k.scale) + 1], all);
      if (r) k.todo.unshift(r);
    }
    // The whole stand-in may be stale now: it stands in only while nothing better is there.
    if (list.length && this.standIn && this.standIn !== k) {
      this.doomed.push(this.standIn.texture);
      this.standIn = null;
    }
  }

  /** A kept view around `view` (device pixels at `scale`), still to build in squares; what
   * `from` holds (another scale or place) is drawn there meanwhile. */
  private newKept(page: number, scale: number, view: number[], from: KeptView | null, bg: number[]): KeptView {
    const w = Math.min(this.maxDim, view[2] - view[0] + 2 * KEPT_MARGIN);
    const h = Math.min(this.maxDim, view[3] - view[1] + 2 * KEPT_MARGIN);
    const x0 = view[0] - ((w - (view[2] - view[0])) >> 1);
    const y0 = view[1] - ((h - (view[3] - view[1])) >> 1);
    const texture = this.device.createTexture({
      size: [w, h],
      format: TARGET_FORMAT,
      usage: GPUTextureUsage.RENDER_ATTACHMENT | GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.COPY_DST | GPUTextureUsage.COPY_SRC,
    });
    const k: KeptView = { texture, page, gen: this.gen, scale, x0, y0, w, h, todo: [], again: [], ms: 0, fresh: true };
    for (let y = y0; y < y0 + h; y += KEPT_TILE) for (let x = x0; x < x0 + w; x += KEPT_TILE) k.todo.push([x, y, Math.min(x0 + w, x + KEPT_TILE), Math.min(y0 + h, y + KEPT_TILE)]);
    const encoder = this.device.createCommandEncoder();
    this.encodeScaled(encoder, from, x0, y0, scale, bg, texture);
    this.device.queue.submit([encoder.finish()]);
    return k;
  }

  /** Kept view `src` drawn at device pixel (`vx`, `vy`) and `scale`: onto the canvas
   * (`into` null) or into a kept view's texture. Nothing kept: the background. */
  private encodeScaled(encoder: GPUCommandEncoder, src: KeptView | null, vx: number, vy: number, scale: number, bg: number[], into: GPUTexture | null): void {
    const step = src ? src.scale / scale : 1;
    const at = src ? [vx * step - src.x0, vy * step - src.y0] : [-1e9, -1e9];
    const u = this.presentUniform([at[0], at[1], step, step, bg[0], bg[1], bg[2], bg[3]]);
    const pass = encoder.beginRenderPass({
      colorAttachments: [{ view: (into ?? this.context.getCurrentTexture()).createView(), loadOp: "clear", storeOp: "store", clearValue: bg }],
    });
    pass.setPipeline(into ? this.fillPipeline : this.scaledPipeline);
    pass.setBindGroup(
      0,
      this.device.createBindGroup({
        layout: this.presentLayout,
        entries: [
          { binding: 0, resource: (src ? src.texture : this.dummy).createView() },
          { binding: 1, resource: { buffer: u } },
        ],
      }),
    );
    pass.draw(3);
    pass.end();
  }

  /** Rect `r` (device pixels) of kept view `k` built by the engine and put in place.
   * False when the engine lacked something it draws (images, CPU layers). */
  private buildRect(engine: Engine, page: number, scale: number, r: number[], k: KeptView, bg: number[], whole: () => boolean): boolean {
    const w = r[2] - r[0];
    const h = r[3] - r[1];
    if (w <= 0 || h <= 0) return true;
    const t0 = performance.now();
    // Bounded by the rect: every glyph mask it needs at once.
    engine.gpuGlyphBudget(Infinity);
    const hdr = engine.gpuPage(page, r[0] / scale, r[1] / scale, scale, w, h);
    const sceneMs = performance.now() - t0;
    const ok = whole();
    const apron = new Uint32Array(engine.memory.buffer, hdr, HEADER_WORDS)[H.apron];
    const tmp = this.acquire(w + 2 * apron, h + 2 * apron);
    const encoder = this.device.createCommandEncoder();
    this.encodeScene(engine, hdr, encoder, tmp, bg, true, ok);
    encoder.copyTextureToTexture({ texture: tmp, origin: [apron, apron] }, { texture: k.texture, origin: [r[0] - k.x0, r[1] - k.y0] }, [w, h]);
    // Each rect goes in its own submit: the frame's buffers are written again for the next.
    this.submit(encoder, t0, sceneMs);
    this.release(tmp);
    return ok && this.stats.pending === 0 && !this.stats.glyphsDeferred;
  }

  // ------------------------------------------------------------------ frames

  /** Draws page `page` with world (x, y) at the canvas's top left, `scale` device pixels
   * per unit, onto the canvas over `background`. `complete`: the engine holds everything
   * the frame draws (its surfaces may be kept), or asked once the scene is built.
   * `present` false draws the frame into its target only: the canvas keeps showing
   * what it showed (`presentLast` puts the target up later). */
  drawPage(engine: Engine, page: number, x: number, y: number, scale: number, background: number[], complete: boolean | (() => boolean) = true, present = true): void {
    this.shownPage = page;
    const w = this.canvas.width;
    const h = this.canvas.height;
    const t0 = performance.now();
    // A frame built off screen (a page switch: the canvas shows the old page veiled)
    // takes every glyph mask it needs at once: drawn a budget a frame, text past the
    // budget is paths, costly on the GPU, and a page of small text would take hundreds
    // of frames to be whole (Untitled UI's landing pages: 185,000 masks at fit, 0.8 s at
    // once against 30 s a budget a frame).
    engine.gpuGlyphBudget(present ? GLYPH_BUDGET : Infinity);
    const hdr = engine.gpuPage(page, x, y, scale, w, h);
    const sceneMs = performance.now() - t0;
    const whole = typeof complete === "function" ? complete() : complete;
    this.lastComplete = whole;
    const apron = new Uint32Array(engine.memory.buffer, hdr, HEADER_WORDS)[H.apron];
    const target = this.ensureTarget(w + 2 * apron, h + 2 * apron);
    const encoder = this.device.createCommandEncoder();
    this.encodeScene(engine, hdr, encoder, target, [background[0], background[1], background[2], 1], true, whole);
    this.lastApron = apron;
    if (present) this.encodePresent(encoder, target, apron, apron);
    this.submit(encoder, t0, sceneMs);
    // Costly to build each frame: the stage keeps the view instead (`drawKept`), starting
    // from this frame when it lacked nothing.
    const fs = Math.fround(scale);
    const st = this.stats;
    this.targetView = { page, gen: this.gen, scale: fs, x0: Math.round(x * fs) - apron, y0: Math.round(y * fs) - apron, apron, whole: whole && st.pending === 0 && !st.glyphsDeferred };
    if (this.keepViews && st.sceneMs + st.encodeMs > COSTLY_MS) this.costly = true;
  }

  /** Whether the last `drawPage` had everything it draws. */
  lastComplete = true;
  private lastApron = 0;

  /** Puts the last frame drawn (with `present` false) onto the canvas. */
  presentLast(): void {
    const target = this.target;
    if (!target) return;
    const encoder = this.device.createCommandEncoder();
    this.encodePresent(encoder, target, this.lastApron, this.lastApron);
    this.device.queue.submit([encoder.finish()]);
  }

  /** A present's uniforms (`Present` in present.wgsl, `Scaled` in scaled.wgsl), fixed
   * when made: several presents and fills in one submit each keep their own. Destroyed
   * once submitted. */
  private presentUniform(values: number[]): GPUBuffer {
    const b = this.device.createBuffer({ size: values.length * 4, usage: GPUBufferUsage.UNIFORM, mappedAtCreation: true });
    new Float32Array(b.getMappedRange()).set(values);
    b.unmap();
    this.doomedBufs.push(b);
    return b;
  }

  private encodePresent(encoder: GPUCommandEncoder, target: GPUTexture, ox: number, oy: number): void {
    const off = this.presentUniform([ox, oy, 0, 0]);
    const pass = encoder.beginRenderPass({
      colorAttachments: [{ view: this.context.getCurrentTexture().createView(), loadOp: "clear", storeOp: "store", clearValue: [0, 0, 0, 1] }],
    });
    pass.setPipeline(this.presentPipeline);
    pass.setBindGroup(
      0,
      this.device.createBindGroup({
        layout: this.presentLayout,
        entries: [
          { binding: 0, resource: target.createView() },
          { binding: 1, resource: { buffer: off } },
        ],
      }),
    );
    pass.draw(3);
    pass.end();
  }

  private submit(encoder: GPUCommandEncoder, t0: number, sceneMs: number): void {
    this.device.queue.submit([encoder.finish()]);
    this.afterSubmit();
    const t1 = performance.now();
    this.stats.sceneMs = sceneMs;
    this.stats.encodeMs = t1 - t0 - sceneMs;
    const no = this.frameNo;
    void this.device.queue.onSubmittedWorkDone().then(() => {
      if (no === this.frameNo) this.stats.gpuMs = performance.now() - t1;
    });
  }

  /** Renders node `id` as an export draws it (`width` x `height` at `scale`) and reads
   * it back as straight RGBA8, waiting for every CPU layer it needs. */
  async renderNode(engine: Engine, id: string, scale: number, width: number, height: number, inspect?: (hdr: number) => void): Promise<{ data: Uint8ClampedArray; stats: GpuStats }> {
    // A document read in pieces: the node's images first.
    await feedOf(engine)?.node(id, scale);
    for (let round = 0; ; round++) {
      const t0 = performance.now();
      engine.gpuMotion(false);
      // Off screen: every glyph mask at once.
      engine.gpuGlyphBudget(Infinity);
      const hdr = engine.gpuNode(id, scale, width, height);
      const sceneMs = performance.now() - t0;
      // Images decoded elsewhere: what the frame lacked is asked for, then drawn again.
      const feed = feedOf(engine);
      if (feed && !feed.rendered() && round < 2000) {
        await feed.node(id, scale);
        await new Promise((r) => setTimeout(r, 20));
        continue;
      }
      const target = this.device.createTexture({
        size: [width, height],
        format: TARGET_FORMAT,
        usage: GPUTextureUsage.RENDER_ATTACHMENT | GPUTextureUsage.COPY_SRC | GPUTextureUsage.TEXTURE_BINDING,
      });
      // A frame built is a frame encoded: its new glyph masks must reach the glyph atlas.
      inspect?.(hdr);
      const encoder = this.device.createCommandEncoder();
      this.encodeScene(engine, hdr, encoder, target, [0, 0, 0, 0], false, true);
      // The canvas's own frames overwrite `stats` while this waits: keep this frame's.
      const snap = { ...this.stats };
      if (snap.pending > 0 && round < 2000) {
        // CPU layers are on their way: wait, then draw again.
        this.device.queue.submit([encoder.finish()]);
        this.afterSubmit();
        target.destroy();
        this.pump();
        await new Promise((r) => setTimeout(r, 20));
        continue;
      }
      const bpr = Math.ceil((width * 8) / 256) * 256;
      const out = this.device.createBuffer({ size: bpr * height, usage: GPUBufferUsage.COPY_DST | GPUBufferUsage.MAP_READ });
      encoder.copyTextureToBuffer({ texture: target }, { buffer: out, bytesPerRow: bpr }, [width, height]);
      this.submit(encoder, t0, sceneMs);
      await out.mapAsync(GPUMapMode.READ);
      const raw = new Uint16Array(out.getMappedRange());
      const data = new Uint8ClampedArray(width * height * 4);
      const to8 = (v: number) => Math.round(Math.min(1, Math.max(0, v)) * 255);
      for (let yy = 0; yy < height; yy++) {
        const row = (yy * bpr) / 2;
        for (let xx = 0; xx < width; xx++) {
          const i = row + xx * 4;
          const a = Math.min(1, Math.max(0, half(raw[i + 3])));
          const o = (yy * width + xx) * 4;
          if (a <= 0) continue;
          data[o] = to8(half(raw[i]) / a);
          data[o + 1] = to8(half(raw[i + 1]) / a);
          data[o + 2] = to8(half(raw[i + 2]) / a);
          data[o + 3] = to8(a);
        }
      }
      out.unmap();
      out.destroy();
      target.destroy();
      return { data, stats: snap };
    }
  }

  /** Encodes the frame the engine built at `hdr`: the atlas, then every draw into
   * `target` (cleared to `clear`). */
  /** The immediate frame at `hdr` (an item of records that blends with the frame) drawn
   * onto `target` as it stands (not cleared). */
  encodeSceneOnto(engine: Engine, hdr: number, encoder: GPUCommandEncoder, target: GPUTexture): void {
    this.encodeScene(engine, hdr, encoder, target, [0, 0, 0, 0], true, true, true);
  }

  private encodeScene(engine: Engine, hdr: number, encoder: GPUCommandEncoder, target: GPUTexture, clear: number[], wanted: boolean, complete: boolean, load = false): void {
    this.frameNo++;
    this.slots.reset();
    const device = this.device;
    const mem = engine.memory.buffer;
    const head = new Uint32Array(mem, hdr, HEADER_WORDS);
    const primCount = head[H.primCount];
    const paintCount = head[H.paintCount];
    const fallbackCount = head[H.fallbackCount];
    const stats = this.stats;
    stats.prims = primCount;
    stats.nodes = head[H.nodes];
    stats.fallbacks = fallbackCount;
    stats.pathEntries = head[H.entryCount];
    stats.atlasLayers = head[H.layerCount];
    stats.glyphs = head[H.glyphDrawCount];
    stats.glyphsNew = head[H.glyphUploadCount];
    stats.glyphsCached = head[H.glyphsCached];
    stats.surfaces = head[H.surfaceCount];
    stats.passes = head[H.passCount];
    // Text drawn as paths for want of glyph budget: the next frame takes more masks.
    const deferred = head[H.glyphsDeferred] > 0;
    stats.glyphsDeferred = head[H.glyphsDeferred];
    if (deferred && wanted) this.onChange();
    stats.features = {};
    for (let i = 1; i < FEATURES.length; i++) if (head[H.features + i]) stats.features[FEATURES[i]] = head[H.features + i];
    stats.reasons = {};
    for (let i = 1; i < REASONS.length; i++) if (head[H.reasons + i]) stats.reasons[REASONS[i]] = head[H.reasons + i];

    // Fallbacks: their layer tiles become extra prims and paints after the engine's.
    const fbWords = new Uint32Array(mem, head[H.fallbacks], fallbackCount * FALLBACK_WORDS);
    const fbFloats = new Float32Array(mem, head[H.fallbacks], fallbackCount * FALLBACK_WORDS);
    const fbInts = new Int32Array(mem, head[H.fallbacks], fallbackCount * FALLBACK_WORDS);
    const primWords = new Uint32Array(mem, head[H.prims], primCount * PRIM_WORDS);
    const fallbacks: Fallback[] = [];
    for (let i = 0; i < fallbackCount; i++) {
      const o = i * FALLBACK_WORDS;
      fallbacks.push({
        id: engine.string(fbWords[o], fbWords[o + 1]),
        part: fbWords[o + 2],
        child: fbWords[o + 3],
        reason: fbWords[o + 4],
        prim: fbWords[o + 5],
        rev: fbWords[o + 6],
        ctm: Array.from(fbFloats.subarray(o + 8, o + 14)),
        rect: Array.from(fbInts.subarray(o + 16, o + 20)),
        full: Array.from(fbInts.subarray(o + 20, o + 24)),
      });
    }
    const extraPrims: number[][] = [];
    const extraPaints: number[][] = [];
    /** Per fallback: the extra prims (index) and their tile textures. */
    const fbDraws: { prim: number; texture: GPUTexture }[][] = [];
    const wantedJobs: LayerJob[] = [];
    let pending = 0;
    const cx = target.width / 2;
    const cy = target.height / 2;
    for (const fb of fallbacks) {
      const list: { prim: number; texture: GPUTexture }[] = [];
      fbDraws.push(list);
      // The node's subtree revision: an edit gives its layers new keys.
      const base = `${this.gen}|${fb.id}|${fb.rev}|${fb.part}|${fb.child}`;
      const ctmKey = fb.ctm.map(f32Key).join(",");
      const tmpl = Array.from(primWords.subarray(fb.prim * PRIM_WORDS, fb.prim * PRIM_WORDS + PRIM_WORDS));
      const ox = tmpl[9] | 0;
      const oy = tmpl[10] | 0;
      const addTile = (t: LayerTile, inv: number[], bounds: number[], filtered: boolean) => {
        const x0 = Math.max(bounds[0], fb.rect[0]);
        const y0 = Math.max(bounds[1], fb.rect[1]);
        const x1 = Math.min(bounds[2], fb.rect[2]);
        const y1 = Math.min(bounds[3], fb.rect[3]);
        if (x1 <= x0 || y1 <= y0) return;
        const paint = paintCount + extraPaints.length;
        extraPaints.push([PAINT_TEXTURE, filtered ? 1 : 0, 0, 0, 0, 0, 0, 0, inv[0], inv[1], inv[2], inv[3], inv[4], inv[5], t.rect[2] - t.rect[0], t.rect[3] - t.rect[1]]);
        const p = tmpl.slice();
        p[0] = x0 + ox;
        p[1] = y0 + oy;
        p[2] = x1 + ox;
        p[3] = y1 + oy;
        p[4] = NONE;
        p[5] = NONE;
        p[7] = paint;
        p[8] = 0;
        p[11] = FEATURE_FALLBACK;
        p[12] = 1;
        p[13] = 0;
        p[14] = NONE;
        list.push({ prim: primCount + extraPrims.length, texture: t.texture });
        extraPrims.push(p);
        t.used = this.frameNo;
      };
      const tx0 = Math.floor(fb.rect[0] / LAYER_TILE);
      const ty0 = Math.floor(fb.rect[1] / LAYER_TILE);
      const tx1 = Math.floor((fb.rect[2] - 1) / LAYER_TILE);
      const ty1 = Math.floor((fb.rect[3] - 1) / LAYER_TILE);
      for (let ty = ty0; ty <= ty1; ty++) {
        for (let tx = tx0; tx <= tx1; tx++) {
          const tr = [
            Math.max(tx * LAYER_TILE, fb.full[0]),
            Math.max(ty * LAYER_TILE, fb.full[1]),
            Math.min((tx + 1) * LAYER_TILE, fb.full[2]),
            Math.min((ty + 1) * LAYER_TILE, fb.full[3]),
          ];
          if (tr[2] <= tr[0] || tr[3] <= tr[1]) continue;
          const key = `${base}@${ctmKey}#${tx},${ty}`;
          const t = this.layers.get(key);
          if (t) {
            addTile(t, [1, 0, 0, 1, -t.rect[0], -t.rect[1]], t.rect, false);
            continue;
          }
          pending++;
          if (!this.inflight.has(key)) {
            const dx = (tr[0] + tr[2]) / 2 + ox - cx;
            const dy = (tr[1] + tr[3]) / 2 + oy - cy;
            wantedJobs.push({ page: this.shownPage, key, base, ctmKey, id: fb.id, part: fb.part, child: fb.child, ctm: fb.ctm, rect: tr, dist: Math.hypot(dx, dy), gen: this.gen });
          }
          // A stand-in: this part's tiles at another matrix, mapped here.
          const inv = invert(fb.ctm);
          const others = this.byBase.get(base);
          if (!inv || !others) continue;
          let best: string | null = null;
          let bestMade = -1;
          for (const k of others) {
            const o = this.layers.get(k);
            if (o && o.ctmKey !== ctmKey && o.made > bestMade) {
              best = o.ctmKey;
              bestMade = o.made;
            }
          }
          if (best === null) continue;
          for (const k of others) {
            const o = this.layers.get(k);
            if (!o || o.ctmKey !== best) continue;
            // New top space to the old tile's texels.
            const toOld = mul(o.ctm, inv);
            const m = mul([1, 0, 0, 1, -o.rect[0], -o.rect[1]], toOld);
            const back = invert(toOld);
            if (!back) continue;
            const pts = [apply(back, o.rect[0], o.rect[1]), apply(back, o.rect[2], o.rect[1]), apply(back, o.rect[0], o.rect[3]), apply(back, o.rect[2], o.rect[3])];
            const bb = [
              Math.floor(Math.min(...pts.map((p) => p[0]))),
              Math.floor(Math.min(...pts.map((p) => p[1]))),
              Math.ceil(Math.max(...pts.map((p) => p[0]))),
              Math.ceil(Math.max(...pts.map((p) => p[1]))),
            ];
            const cut = [Math.max(bb[0], tr[0]), Math.max(bb[1], tr[1]), Math.min(bb[2], tr[2]), Math.min(bb[3], tr[3])];
            addTile(o, m, cut, true);
          }
        }
      }
    }
    stats.pending = pending;
    if (wanted || pending) {
      wantedJobs.sort((a, b) => a.dist - b.dist);
      this.queue = wantedJobs;
      this.pump();
    }

    // Upload.
    const primBytes = (primCount + extraPrims.length) * PRIM_WORDS * 4;
    const paintBytes = (paintCount + extraPaints.length) * PAINT_WORDS * 4;
    const shapeBytes = head[H.shapeCount] * SHAPE_WORDS * 4;
    const stopBytes = head[H.stopCount] * 16;
    const storage = GPUBufferUsage.STORAGE;
    const primBuf = this.buffer("prims", primBytes + 64, storage);
    const paintBuf = this.buffer("paints", paintBytes + 64, storage);
    const shapeBuf = this.buffer("shapes", shapeBytes + 128, storage);
    const stopBuf = this.buffer("stops", stopBytes + 16, storage);
    const q = device.queue;
    if (primCount) q.writeBuffer(primBuf, 0, new Uint8Array(mem, head[H.prims], primCount * PRIM_WORDS * 4));
    if (extraPrims.length) {
      const words = new Uint32Array(extraPrims.length * PRIM_WORDS);
      const floats = new Float32Array(words.buffer);
      extraPrims.forEach((p, i) => {
        const o = i * PRIM_WORDS;
        for (let k = 0; k < PRIM_WORDS; k++) {
          // Bounds and opacity are floats; the rest stay as the engine's words.
          if (k < 4 || k === 12) floats[o + k] = p[k];
          else words[o + k] = p[k] >>> 0;
        }
      });
      q.writeBuffer(primBuf, primCount * PRIM_WORDS * 4, words);
    }
    if (paintCount) q.writeBuffer(paintBuf, 0, new Uint8Array(mem, head[H.paints], paintCount * PAINT_WORDS * 4));
    if (extraPaints.length) {
      const words = new Uint32Array(extraPaints.length * PAINT_WORDS);
      const floats = new Float32Array(words.buffer);
      extraPaints.forEach((p, i) => {
        const o = i * PAINT_WORDS;
        for (let k = 0; k < PAINT_WORDS; k++) {
          if (k < 4) words[o + k] = p[k];
          else floats[o + k] = p[k];
        }
      });
      q.writeBuffer(paintBuf, paintCount * PAINT_WORDS * 4, words);
    }
    if (shapeBytes) q.writeBuffer(shapeBuf, 0, new Uint8Array(mem, head[H.shapes], shapeBytes));
    if (stopBytes) q.writeBuffer(stopBuf, 0, new Uint8Array(mem, head[H.stops], stopBytes));

    // New glyph masks into the glyph atlas: a few one by one; many (a page of small text
    // at a new scale: 185,000) into a copy of the atlas here, then the rows they touch
    // in one upload.
    const upCount = head[H.glyphUploadCount];
    const ups = new Uint32Array(mem, head[H.glyphUploads], upCount * 8);
    if (upCount <= GLYPH_UPLOADS_ONE_BY_ONE) {
      for (let i = 0; i < upCount; i++) {
        const o = i * 8;
        const gw = ups[o + 2];
        const gh = ups[o + 3];
        const data = new Uint8Array(mem, ups[o + 4], gw * gh);
        q.writeTexture({ texture: this.glyphAtlas, origin: [ups[o], ups[o + 1]] }, data, { bytesPerRow: gw }, [gw, gh]);
        for (let r = 0; r < gh; r++) this.glyphCopy.set(data.subarray(r * gw, (r + 1) * gw), (ups[o + 1] + r) * GLYPH_ATLAS + ups[o]);
      }
    } else {
      const copy = this.glyphCopy;
      const bytes = new Uint8Array(mem);
      let y0 = GLYPH_ATLAS;
      let y1 = 0;
      for (let i = 0; i < upCount; i++) {
        const o = i * 8;
        const gx = ups[o];
        const gy = ups[o + 1];
        const gw = ups[o + 2];
        const gh = ups[o + 3];
        const src = ups[o + 4];
        for (let r = 0; r < gh; r++) copy.set(bytes.subarray(src + r * gw, src + (r + 1) * gw), (gy + r) * GLYPH_ATLAS + gx);
        y0 = Math.min(y0, gy);
        y1 = Math.max(y1, gy + gh);
      }
      q.writeTexture({ texture: this.glyphAtlas, origin: [0, y0] }, copy.subarray(y0 * GLYPH_ATLAS, y1 * GLYPH_ATLAS), { bytesPerRow: GLYPH_ATLAS }, [GLYPH_ATLAS, y1 - y0]);
    }

    // The path atlas.
    let drawCalls = 0;
    const layerCount = head[H.layerCount];
    this.ensureAtlas(Math.max(1, layerCount));
    if (layerCount) {
      const vertBytes = head[H.vertCount] * 8;
      const vertBuf = this.buffer("verts", vertBytes + 8, GPUBufferUsage.VERTEX);
      if (vertBytes) q.writeBuffer(vertBuf, 0, new Uint8Array(mem, head[H.verts], vertBytes));
      const entries = new Uint32Array(mem, head[H.entries], head[H.entryCount] * 8);
      const layers = new Uint32Array(mem, head[H.layers], layerCount * LAYER_WORDS);
      const glyphBytes = head[H.glyphDrawCount] * 32;
      const glyphBuf = this.buffer("glyphs", glyphBytes + 32, GPUBufferUsage.VERTEX);
      if (glyphBytes) q.writeBuffer(glyphBuf, 0, new Uint8Array(mem, head[H.glyphDraws], glyphBytes));
      // Cover rects per layer, nonzero ones then even-odd ones.
      const rects = new Uint32Array(head[H.entryCount] * 4);
      const spans: number[][] = [];
      let n = 0;
      for (let l = 0; l < layerCount; l++) {
        const first = layers[l * LAYER_WORDS + 2];
        const count = layers[l * LAYER_WORDS + 3];
        const span: number[] = [n, 0, 0];
        for (const rule of [0, 1]) {
          for (let e = first; e < first + count; e++) {
            const o = e * 8;
            if (entries[o + 1] !== rule) continue;
            rects.set([entries[o + 2], entries[o + 3], entries[o + 4], entries[o + 5]], n * 4);
            n++;
            span[rule + 1]++;
          }
        }
        spans.push(span);
      }
      const rectBuf = this.buffer("covers", rects.byteLength + 16, GPUBufferUsage.VERTEX);
      if (n) q.writeBuffer(rectBuf, 0, rects, 0, n * 4);
      for (let l = 0; l < layerCount; l++) {
        const pass = encoder.beginRenderPass({
          colorAttachments: [{ view: this.msaaColor.createView(), resolveTarget: this.atlasViews[l], loadOp: "clear", storeOp: "discard", clearValue: [0, 0, 0, 0] }],
          depthStencilAttachment: { view: this.msaaStencil.createView(), stencilLoadOp: "clear", stencilStoreOp: "discard", stencilClearValue: 0 },
        });
        pass.setBindGroup(0, this.atlasGroup);
        pass.setStencilReference(0);
        const vf = layers[l * LAYER_WORDS];
        const vc = layers[l * LAYER_WORDS + 1];
        if (vc) {
          pass.setPipeline(this.stencilPipeline);
          pass.setVertexBuffer(0, vertBuf, vf * 8, vc * 8);
          pass.draw(vc);
          drawCalls++;
        }
        const [start, nonzero, evenodd] = spans[l];
        pass.setVertexBuffer(0, rectBuf);
        if (nonzero) {
          pass.setPipeline(this.coverPipelines[0]);
          pass.draw(4, nonzero, 0, start);
          drawCalls++;
        }
        if (evenodd) {
          pass.setPipeline(this.coverPipelines[1]);
          pass.draw(4, evenodd, 0, start + nonzero);
          drawCalls++;
        }
        pass.end();
        const gf = layers[l * LAYER_WORDS + 4];
        const gc = layers[l * LAYER_WORDS + 5];
        if (gc) {
          const gp = encoder.beginRenderPass({ colorAttachments: [{ view: this.atlasViews[l], loadOp: "load", storeOp: "store" }] });
          gp.setPipeline(this.glyphPipeline);
          gp.setBindGroup(0, this.atlasGroup);
          gp.setVertexBuffer(0, glyphBuf);
          gp.draw(4, gc, 0, gf);
          gp.end();
          drawCalls++;
        }
      }
    }

    // Surfaces: kept ones as they are, the rest drawn this frame.
    const surfCount = head[H.surfaceCount];
    const surfWords = new Uint32Array(mem, head[H.surfaces], surfCount * SURFACE_WORDS);
    const surfInts = new Int32Array(mem, head[H.surfaces], surfCount * SURFACE_WORDS);
    const surfTex: (GPUTexture | null)[] = new Array(surfCount).fill(null);
    const surfKey: string[] = [];
    for (let s = 0; s < surfCount; s++) surfKey.push(`${surfWords[s * SURFACE_WORDS + 6]}:${surfWords[s * SURFACE_WORDS + 5]}`);
    const drawn: GPUTexture[] = [];
    const passWords = new Uint32Array(mem, head[H.passes], head[H.passCount] * PASS_WORDS);
    const passInts = new Int32Array(mem, head[H.passes], head[H.passCount] * PASS_WORDS);
    const passFloats = new Float32Array(mem, head[H.passes], head[H.passCount] * PASS_WORDS);
    // Pixels drawn this frame may be kept only when the frame lacked nothing.
    const keepable = this.keep && complete && !deferred && pending === 0;

    // The draws.
    const g0Of = new Map<number, GPUBindGroup>();
    const g0Base = { primBuf, shapeBuf, paintBuf, stopBuf };
    const stack: Target[] = [{ texture: target, w: target.width, h: target.height, cleared: load, ops: null, reads: new Set() }];
    const sizeSlots = new Map<string, number>();
    const sizeSlot = (w: number, h: number) => {
      const key = `${w}x${h}`;
      let o = sizeSlots.get(key);
      if (o === undefined) {
        const s = this.slots.take();
        s.f32[0] = w;
        s.f32[1] = h;
        o = s.offset;
        sizeSlots.set(key, o);
      }
      return o;
    };
    const g0 = () => {
      // One bind group for every pass (the slot buffer may grow: made at the end).
      let g = g0Of.get(0);
      if (!g) {
        g = device.createBindGroup({
          layout: this.g0Layout,
          entries: [
            { binding: 0, resource: { buffer: this.slotBuf, size: 16 } },
            { binding: 1, resource: { buffer: g0Base.primBuf } },
            { binding: 2, resource: { buffer: g0Base.shapeBuf } },
            { binding: 3, resource: { buffer: g0Base.paintBuf } },
            { binding: 4, resource: { buffer: g0Base.stopBuf } },
            { binding: 5, resource: this.atlas!.createView({ dimension: "2d-array" }) },
          ],
        });
        g0Of.set(0, g);
      }
      return g;
    };
    // Render passes and compute passes are recorded later, once the slot buffer is
    // final: each step is a closure run in order.
    //
    // Every target keeps one render pass open while the walk goes into surfaces and back:
    // a surface's passes go out when it ends, before its parent's, so a target is
    // loaded and stored once, not once per surface drawn inside it (on a tiled GPU each
    // pass loads and stores the whole attachment: a page of thousands of small surfaces
    // spent seconds of GPU time on the canvas's target). A target's open pass goes out
    // early only when something must see what it holds (a backdrop read) or a pass
    // changes a surface it reads.
    const steps: ((enc: GPUCommandEncoder) => void)[] = [];
    const flushTarget = (t: Target) => {
      const ops = t.ops;
      if (!ops) return;
      t.ops = null;
      t.reads.clear();
      // Whether this pass clears is decided now (the flag changes before steps run).
      const loadOp: GPULoadOp = t.cleared ? "load" : "clear";
      const clearValue = t === stack[0] ? clear : [0, 0, 0, 0];
      const texture = t.texture;
      steps.push((enc) => {
        const p = enc.beginRenderPass({
          colorAttachments: [{ view: texture.createView(), loadOp, storeOp: "store", clearValue }],
        });
        for (const op of ops) op(p);
        p.end();
      });
      t.cleared = true;
    };
    /** Every open pass out (before the shared backdrop texture is written again). */
    const flushAll = () => {
      for (const t of stack) flushTarget(t);
    };
    /** Open passes that read surface `s` out (before a pass writes it). */
    const flushReaders = (s: number) => {
      for (const t of stack) if (t.reads.has(s)) flushTarget(t);
    };
    const top = () => stack[stack.length - 1];
    const record = (op: (p: GPURenderPassEncoder) => void, reads: number[] = NO_READS) => {
      const t = top();
      if (!t.ops) {
        // Prims address the target's texels: NDC over the whole texture.
        const slot = sizeSlot(t.texture.width, t.texture.height);
        t.ops = [(p) => p.setBindGroup(0, g0(), [slot])];
      }
      t.ops.push(op);
      for (const r of reads) t.reads.add(r);
    };
    const texOf = (code: number): GPUTextureView | null => {
      if (code === NONE) return null;
      if (code & SURFACE_BIT) {
        const t = surfTex[code & ~SURFACE_BIT];
        return t ? t.createView() : null;
      }
      return this.image(engine, texRecs, code).view;
    };
    /** The surfaces a draw's texture and mask codes read. */
    const surfReads = (a: number, b: number): number[] => {
      const out: number[] = [];
      if (a !== NONE && a & SURFACE_BIT) out.push(a & ~SURFACE_BIT);
      if (b !== NONE && b & SURFACE_BIT) out.push(b & ~SURFACE_BIT);
      return out.length ? out : NO_READS;
    };
    const texRecs = new Uint32Array(mem, head[H.textures], head[H.textureCount] * 8);
    const primFloats = new Float32Array(mem, head[H.prims], primCount * PRIM_WORDS);
    const draws = new Uint32Array(mem, head[H.draws], head[H.drawCount] * DRAW_WORDS);
    let surfacesDrawn = 0;
    const drawCount = head[H.drawCount];
    for (let i = 0; i < drawCount; i++) {
      const o = i * DRAW_WORDS;
      const kind = draws[o];
      const first = draws[o + 1];
      const count = draws[o + 2];
      if (kind === DRAW_PRIMS) {
        const tex = texOf(draws[o + 3]);
        const mask = texOf(draws[o + 4]);
        const flags = draws[o + 5];
        if ((draws[o + 3] !== NONE && !tex) || (draws[o + 4] !== NONE && !mask)) continue;
        if (flags & FLAG_BACKDROP) {
          // What is under the prim, copied first (one prim per draw).
          for (let k = first; k < first + count; k++) {
            const b = k * PRIM_WORDS;
            const t = top();
            const x0 = Math.max(0, Math.floor(primFloats[b]));
            const y0 = Math.max(0, Math.floor(primFloats[b + 1]));
            const x1 = Math.min(t.w, Math.ceil(primFloats[b + 2]));
            const y1 = Math.min(t.h, Math.ceil(primFloats[b + 3]));
            if (x1 <= x0 || y1 <= y0) continue;
            if (!t.cleared && !t.ops) {
              // Nothing drawn here yet: clear it first.
              record(() => {});
            }
            // The copy sees what the target holds; the shared backdrop texture is free
            // again once every pass that read it is out.
            flushAll();
            const bd = this.backdropFor(x1 - x0, y1 - y0);
            const src = t.texture;
            steps.push((enc) => enc.copyTextureToTexture({ texture: src, origin: [x0, y0] }, { texture: bd }, [x1 - x0, y1 - y0]));
            const group = this.group1(tex ?? this.dummyView, bd.createView(), mask);
            record((p) => {
              p.setPipeline(this.paintPipelines.replace);
              p.setBindGroup(1, group);
              p.draw(4, 1, 0, k);
            }, surfReads(draws[o + 3], draws[o + 4]));
            drawCalls++;
          }
          continue;
        }
        const group = tex || mask ? this.group1(tex ?? this.dummyView, null, mask) : this.dummyGroup;
        const pipe = flags & FLAG_MAX ? this.paintPipelines.max : flags & FLAG_ERASE ? this.paintPipelines.erase : this.paintPipelines.over;
        record(
          (p) => {
            p.setPipeline(pipe);
            p.setBindGroup(1, group);
            p.draw(4, count, 0, first);
          },
          surfReads(draws[o + 3], draws[o + 4]),
        );
        drawCalls++;
      } else if (kind === DRAW_FALLBACK) {
        for (const t of fbDraws[draws[o + 3]]) {
          const group = this.group1(t.texture.createView(), null, null);
          record((p) => {
            p.setPipeline(this.paintPipelines.over);
            p.setBindGroup(1, group);
            p.draw(4, 1, 0, t.prim);
          });
          drawCalls++;
        }
      } else if (kind === DRAW_BEGIN) {
        const s = first;
        const so = s * SURFACE_WORDS;
        const w = surfWords[so];
        const h = surfWords[so + 1];
        const key = surfKey[s];
        const cacheable = (surfWords[so + 4] & 1) !== 0;
        const k = cacheable && this.keep ? this.kept.get(key) : undefined;
        if (k && k.texture.width >= w && k.texture.height >= h) {
          k.used = this.frameNo;
          surfTex[s] = k.texture;
          // Skip to its end.
          i = surfWords[so + 8] * 1;
          continue;
        }
        const t = this.acquire(Math.max(1, w), Math.max(1, h));
        surfTex[s] = t;
        drawn.push(t);
        surfacesDrawn++;
        stack.push({ texture: t, w, h, cleared: false, ops: null, reads: new Set() });
        // Cleared even when nothing draws into it.
        record(() => {});
      } else if (kind === DRAW_END) {
        flushTarget(top());
        stack.pop();
        const s = first;
        const cacheable = (surfWords[s * SURFACE_WORDS + 4] & 1) !== 0;
        if (keepable && cacheable && surfTex[s] && !this.kept.has(surfKey[s])) {
          const tex = surfTex[s]!;
          this.kept.set(surfKey[s], { key: surfKey[s], texture: tex, bytes: tex.width * tex.height * 8, used: this.frameNo });
          this.keptBytes += tex.width * tex.height * 8;
          const at = drawn.indexOf(tex);
          if (at >= 0) drawn.splice(at, 1);
        }
        // (A surface already kept under this key was skipped at its begin.)
        void surfInts;
      } else if (kind === DRAW_PASS) {
        const po = first * PASS_WORDS;
        const pk = passWords[po];
        const srcS = passWords[po + 1];
        const dstS = passWords[po + 2];
        const dstTex = surfTex[dstS];
        if (!dstTex) continue;
        // What read the surface before this pass changes it goes out first, and what was
        // drawn into the surfaces it reads or writes.
        flushReaders(dstS);
        const srcTex0 = srcS !== NONE ? surfTex[srcS] : null;
        for (const t of stack) if (t.texture === dstTex || t.texture === srcTex0) flushTarget(t);
        const ds = dstS * SURFACE_WORDS;
        const size = [surfWords[ds], surfWords[ds + 1], surfInts[ds + 2], surfInts[ds + 3]];
        const fill = (dir: number, stepNo: number) => {
          const s = this.slots.take();
          s.u32[0] = pk;
          s.u32[1] = dir;
          s.u32[2] = stepNo;
          s.i32.set(size, 4);
          s.i32.set(passInts.subarray(po + 4, po + 12), 8);
          s.f32.set(passFloats.subarray(po + 12, po + 32), 16);
          return s.offset;
        };
        const dispatch = (entry: string, src: GPUTexture, dst: GPUTexture, dir: number, stepNo: number, perLine = false) => {
          const offset = fill(dir, stepNo);
          const w = size[0];
          const h = size[1];
          steps.push((enc) => {
            const group = device.createBindGroup({
              layout: this.fxLayout,
              entries: [
                { binding: 0, resource: { buffer: this.slotBuf, size: 144 } },
                { binding: 1, resource: src.createView() },
                { binding: 2, resource: dst.createView() },
              ],
            });
            const cp = enc.beginComputePass();
            cp.setPipeline(this.fxPipelines[entry]);
            cp.setBindGroup(0, group, [offset]);
            if (perLine) cp.dispatchWorkgroups(Math.ceil((dir === 0 ? h : w) / 64));
            else cp.dispatchWorkgroups(Math.ceil(w / 8), Math.ceil(h / 8));
            cp.end();
          });
        };
        const tmp = this.acquire(dstTex.width, dstTex.height);
        drawn.push(tmp);
        const copy = (from: GPUTexture, to: GPUTexture) => steps.push((enc) => enc.copyTextureToTexture({ texture: from }, { texture: to }, [from.width, from.height]));
        if (pk === PASS_GAUSS || pk === PASS_PROGRESSIVE || pk === PASS_SPREAD) {
          const entry = pk === PASS_GAUSS ? "gauss" : pk === PASS_PROGRESSIVE ? "progressive" : "spread";
          dispatch(entry, dstTex, tmp, 0, 0);
          dispatch(entry, tmp, dstTex, 1, 0);
        } else if (pk === PASS_BOX3) {
          for (let b = 0; b < 3; b++) {
            dispatch("box", dstTex, tmp, 0, b, true);
            dispatch("box", tmp, dstTex, 1, b, true);
          }
        } else if (pk === PASS_NOISE || pk === PASS_TEXTURE) {
          const srcTex = srcS !== NONE ? surfTex[srcS] : null;
          if (!srcTex) continue;
          copy(srcTex, tmp);
          dispatch(pk === PASS_NOISE ? "noise" : "texture", tmp, dstTex, 0, 0);
        } else if (pk === PASS_BACKDROP) {
          const t = top();
          if (!t.cleared && !t.ops) record(() => {});
          flushTarget(t);
          dispatch("backdrop", t.texture, dstTex, 0, 0);
        }
        drawCalls++;
      }
    }
    // A frame with nothing in it is its background.
    if (!stack[0].cleared && !stack[0].ops) record(() => {});
    flushAll();
    // The slots are final: upload them, then record.
    const slotBytes = this.slots.used * SLOT;
    if (this.slotBuf.size < slotBytes) {
      this.slotBuf.destroy();
      let size = this.slotBuf.size;
      while (size < slotBytes) size *= 2;
      this.slotBuf = device.createBuffer({ size, usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST });
    }
    if (slotBytes) q.writeBuffer(this.slotBuf, 0, this.slots.data, 0, slotBytes);
    for (const step of steps) step(encoder);
    // Textures of this frame go back to the pool once the GPU is done with them (the
    // queue keeps its order: later frames' writes come after).
    for (const t of drawn) this.release(t);
    stats.surfacesDrawn = surfacesDrawn;
    stats.drawCalls = drawCalls;
    let bytes = 0;
    for (const i of this.images.values()) bytes += i.bytes;
    stats.keptBytes = this.keptBytes;
    stats.textureBytes = bytes + this.layerBytes + this.keptBytes + this.freeBytes + (this.atlas ? this.atlas.depthOrArrayLayers * ATLAS_SIZE * ATLAS_SIZE : 0) + ATLAS_SIZE * ATLAS_SIZE * 8 + target.width * target.height * 8;
  }

  // ------------------------------------------------------------------ CPU layers

  /** Starts layer tiles on free workers, nearest the centre first. */
  pump(): void {
    const pool = this.pool;
    if (!pool) return;
    for (const slot of pool.slots) {
      if (slot.busy || !slot.ready) continue;
      let job = this.queue.shift();
      while (job && (this.inflight.has(job.key) || this.layers.has(job.key))) job = this.queue.shift();
      if (!job) return;
      void this.run(slot, job);
    }
  }

  private async run(slot: Slot, job: LayerJob): Promise<void> {
    const pool = this.pool!;
    slot.busy = true;
    this.inflight.set(job.key, job);
    const [x0, y0, x1, y1] = job.rect;
    let r: Record<string, unknown> | null = null;
    try {
      r = await pool.call(slot, { type: "layer", page: job.page, node: job.id, part: job.part, child: job.child, m: job.ctm, x0, y0, w: x1 - x0, h: y1 - y0 });
    } catch (err) {
      console.error("layer", job.key, err);
    }
    slot.busy = false;
    this.inflight.delete(job.key);
    if (r && job.gen === this.gen) {
      const w = x1 - x0;
      const h = y1 - y0;
      const texture = this.device.createTexture({ size: [w, h], format: "rgba8unorm", usage: GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.COPY_DST });
      this.device.queue.writeTexture({ texture }, r.data as Uint8Array, { bytesPerRow: w * 4 }, [w, h]);
      const tile: LayerTile = { key: job.key, base: job.base, ctmKey: job.ctmKey, ctm: job.ctm, rect: job.rect, texture, bytes: w * h * 4, used: this.frameNo, made: performance.now() };
      this.layers.set(job.key, tile);
      let set = this.byBase.get(job.base);
      if (!set) this.byBase.set(job.base, (set = new Set()));
      set.add(job.key);
      this.layerBytes += tile.bytes;
      this.layerTimings.push({ ms: r.ms as number, w, h });
      if (this.layerTimings.length > 4000) this.layerTimings.shift();
    }
    this.pump();
    this.onChange();
  }

  /** Drops the least recently drawn layer tiles and kept surfaces past their caps
   * (never this frame's). */
  private evict(): void {
    if (this.layerBytes > this.layerCap) {
      const list = [...this.layers.values()].filter((t) => t.used < this.frameNo).sort((a, b) => a.used - b.used);
      for (const t of list) {
        if (this.layerBytes <= this.layerCap * 0.9) break;
        t.texture.destroy();
        this.layerBytes -= t.bytes;
        this.layers.delete(t.key);
        this.byBase.get(t.base)?.delete(t.key);
      }
    }
    if (this.keptBytes > this.keptCap) {
      const list = [...this.kept.values()].filter((k) => k.used < this.frameNo).sort((a, b) => a.used - b.used);
      for (const k of list) {
        if (this.keptBytes <= this.keptCap * 0.8) break;
        this.kept.delete(k.key);
        this.keptBytes -= k.bytes;
        this.release(k.texture);
      }
    }
  }

  /** What waits for a frame to be submitted: textures past their budgets go. */
  private afterSubmit(): void {
    this.evict();
    this.trimFree();
    for (const t of this.doomed) t.destroy();
    this.doomed = [];
    for (const b of this.doomedBufs) b.destroy();
    this.doomedBufs = [];
  }

  // ------------------------------------------------------------------ for records.ts

  /** A pooled render target of at least `w` x `h` (give it back with `releaseTarget`). */
  tempTarget(w: number, h: number): GPUTexture {
    return this.acquire(w, h);
  }

  releaseTarget(t: GPUTexture): void {
    this.release(t);
  }

  /** The immediate frame the engine built at `hdr` (an item of records) drawn into
   * `target`, cleared to transparent. */
  encodeSceneInto(engine: Engine, hdr: number, encoder: GPUCommandEncoder, target: GPUTexture, complete: boolean): void {
    this.encodeScene(engine, hdr, encoder, target, [0, 0, 0, 0], true, complete);
  }

  /** The effect passes of the immediate frame at `hdr` run on its first surface (an
   * item of records' background blur: its backdrop read from `target`, where the frame
   * stands, then blurred), recorded into `encoder`. The surface, and its rect in top
   * space; null when the frame has none. */
  runScenePasses(engine: Engine, hdr: number, encoder: GPUCommandEncoder, target: GPUTexture): { texture: GPUTexture; rect: number[] } | null {
    const mem = engine.memory.buffer;
    const head = new Uint32Array(mem, hdr, HEADER_WORDS);
    if (!head[H.surfaceCount]) return null;
    const sw = new Uint32Array(mem, head[H.surfaces], SURFACE_WORDS);
    const si = new Int32Array(mem, head[H.surfaces], SURFACE_WORDS);
    const size = [sw[0], sw[1], si[2], si[3]];
    if (size[0] <= 0 || size[1] <= 0) return null;
    const passCount = head[H.passCount];
    const pw = new Uint32Array(mem, head[H.passes], passCount * PASS_WORDS).slice();
    const pi = new Int32Array(pw.buffer);
    const pf = new Float32Array(pw.buffer);
    const surf = this.acquire(size[0], size[1]);
    const tmp = this.acquire(size[0], size[1]);
    const device = this.device;
    const dispatch = (entry: string, kind: number, o: number, src: GPUTexture, dst: GPUTexture, dir: number, stepNo: number, perLine = false) => {
      const u = new ArrayBuffer(144);
      const u32 = new Uint32Array(u);
      const i32 = new Int32Array(u);
      const f = new Float32Array(u);
      u32[0] = kind;
      u32[1] = dir;
      u32[2] = stepNo;
      i32.set(size, 4);
      i32.set(pi.subarray(o + 4, o + 12), 8);
      f.set(pf.subarray(o + 12, o + 32), 16);
      const b = device.createBuffer({ size: SLOT, usage: GPUBufferUsage.UNIFORM, mappedAtCreation: true });
      new Uint8Array(b.getMappedRange()).set(new Uint8Array(u));
      b.unmap();
      this.doomedBufs.push(b);
      const group = device.createBindGroup({
        layout: this.fxLayout,
        entries: [
          { binding: 0, resource: { buffer: b, size: 144 } },
          { binding: 1, resource: src.createView() },
          { binding: 2, resource: dst.createView() },
        ],
      });
      const cp = encoder.beginComputePass();
      cp.setPipeline(this.fxPipelines[entry]);
      cp.setBindGroup(0, group, [0]);
      if (perLine) cp.dispatchWorkgroups(Math.ceil((dir === 0 ? size[1] : size[0]) / 64));
      else cp.dispatchWorkgroups(Math.ceil(size[0] / 8), Math.ceil(size[1] / 8));
      cp.end();
    };
    for (let k = 0; k < passCount; k++) {
      const o = k * PASS_WORDS;
      const pk = pw[o];
      if (pk === PASS_BACKDROP) dispatch("backdrop", pk, o, target, surf, 0, 0);
      else if (pk === PASS_GAUSS || pk === PASS_PROGRESSIVE || pk === PASS_SPREAD) {
        const entry = pk === PASS_GAUSS ? "gauss" : pk === PASS_PROGRESSIVE ? "progressive" : "spread";
        dispatch(entry, pk, o, surf, tmp, 0, 0);
        dispatch(entry, pk, o, tmp, surf, 1, 0);
      } else if (pk === PASS_BOX3) {
        for (let bx = 0; bx < 3; bx++) {
          dispatch("box", pk, o, surf, tmp, 0, bx, true);
          dispatch("box", pk, o, tmp, surf, 1, bx, true);
        }
      }
    }
    this.release(tmp);
    return { texture: surf, rect: [size[2], size[3], size[2] + size[0], size[3] + size[1]] };
  }

  /** Destroys `b` once the frame using it is submitted. */
  doomBuffer(b: GPUBuffer): void {
    this.doomedBufs.push(b);
  }

  /** Destroys `t` once the frame using it is submitted. */
  doom(t: GPUTexture): void {
    this.doomed.push(t);
  }

  /** Puts `texture` (a frame's target) onto the canvas. */
  presentTexture(encoder: GPUCommandEncoder, texture: GPUTexture): void {
    this.encodePresent(encoder, texture, 0, 0);
  }

  /** What follows a submitted frame: textures past their budgets go. */
  afterFrame(): void {
    this.afterSubmit();
  }

  /** A target texture (rgba16float, premultiplied) read back as straight RGBA8. */
  async readTexture(target: GPUTexture): Promise<{ width: number; height: number; data: Uint8ClampedArray }> {
    const width = target.width;
    const height = target.height;
    const bpr = Math.ceil((width * 8) / 256) * 256;
    const out = this.device.createBuffer({ size: bpr * height, usage: GPUBufferUsage.COPY_DST | GPUBufferUsage.MAP_READ });
    const encoder = this.device.createCommandEncoder();
    encoder.copyTextureToBuffer({ texture: target }, { buffer: out, bytesPerRow: bpr }, [width, height]);
    this.device.queue.submit([encoder.finish()]);
    await out.mapAsync(GPUMapMode.READ);
    const raw = new Uint16Array(out.getMappedRange());
    const data = new Uint8ClampedArray(width * height * 4);
    const to8 = (v: number) => Math.round(Math.min(1, Math.max(0, v)) * 255);
    for (let yy = 0; yy < height; yy++) {
      const row = (yy * bpr) / 2;
      for (let xx = 0; xx < width; xx++) {
        const i = row + xx * 4;
        const a = Math.min(1, Math.max(0, half(raw[i + 3])));
        const o = (yy * width + xx) * 4;
        if (a <= 0) continue;
        data[o] = to8(half(raw[i]) / a);
        data[o + 1] = to8(half(raw[i + 1]) / a);
        data[o + 2] = to8(half(raw[i + 2]) / a);
        data[o + 3] = to8(a);
      }
    }
    out.unmap();
    out.destroy();
    return { width, height, data };
  }

  /** Layer tiles queued or drawing. */
  pendingLayers(): number {
    return this.stats.pending;
  }
}
