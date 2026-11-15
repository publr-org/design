// Checks for the console or a test driver (`window.viewer`): the WASM build against the
// native one, the GPU canvas against the CPU engine, tile timings, time until sharp,
// frame rate while moving, and memory.

import type { Stage, Timing } from "./stage";
import { MAX_ZOOM, MIN_ZOOM } from "./stage";

type Summary = { count: number; p50: number; p90: number; max: number; empty: number };

const percentile = (sorted: number[], p: number) => (sorted.length ? sorted[Math.min(sorted.length - 1, Math.floor(p * sorted.length))] : 0);
const round = (v: number) => Math.round(v * 10) / 10;

function summarize(list: Timing[]): Summary {
  const ms = list.map((t) => t.ms).sort((a, b) => a - b);
  return { count: ms.length, p50: round(percentile(ms, 0.5)), p90: round(percentile(ms, 0.9)), max: round(ms[ms.length - 1] ?? 0), empty: list.filter((t) => t.empty).length };
}

/** Counts differing bytes and the largest difference. */
function diff(a: Uint8ClampedArray | Uint8Array, b: Uint8Array): { differing: number; max: number } {
  let differing = 0;
  let max = 0;
  for (let i = 0; i < a.length; i++) {
    const d = Math.abs(a[i] - b[i]);
    if (d) differing++;
    if (d > max) max = d;
  }
  return { differing, max };
}

/** Pixels whose channels all lie within 2/255 of the reference, and the largest
 * difference. */
function agreement(a: Uint8ClampedArray, b: Uint8ClampedArray | Uint8Array): { within2: number; max: number; pixels: number; off: number } {
  let off = 0;
  let max = 0;
  const pixels = a.length / 4;
  for (let i = 0; i < a.length; i += 4) {
    let d = 0;
    for (let k = 0; k < 4; k++) d = Math.max(d, Math.abs(a[i + k] - b[i + k]));
    if (d > 2) off++;
    if (d > max) max = d;
  }
  return { within2: pixels ? Math.round((1 - off / pixels) * 10000) / 100 : 100, max, pixels, off };
}

const wait = (ms: number) => new Promise((r) => setTimeout(r, ms));

export function installChecks(stage: Stage): void {
  const checks = {
    stage,

    /** A top-level node at `scale`: the WASM export and a WASM tile over the node's box,
     * each against the native `pe render` of the same node. */
    async compare(nodeId: string, scale = 1) {
      const pool = stage.pool!;
      const pg = stage.currentPage()!;
      const f = pg.frames.find((x) => x.id === nodeId);
      if (!f) throw new Error(`${nodeId} is not a top-level node of this page`);
      const slot = pool.slots[0];
      const exp = await pool.call(slot, { type: "node", node: nodeId, scale, page: stage.page });
      const tile = await pool.call(slot, { type: "rect", page: stage.page, x: f.box[0], y: f.box[1], scale, width: exp.width, height: exp.height });
      const r = await fetch(`/api/render?node=${encodeURIComponent(nodeId)}&scale=${scale}`);
      const native = new Uint8Array(await r.arrayBuffer());
      return {
        node: nodeId,
        scale,
        size: [exp.width, exp.height],
        nativeSize: [Number(r.headers.get("x-width")), Number(r.headers.get("x-height"))],
        exportVsNative: diff(exp.data as Uint8ClampedArray, native),
        tileVsNative: diff(tile.data as Uint8ClampedArray, native),
      };
    },

    /** Tile render times so far, overall and per level. */
    timings() {
      const levels: Record<string, Timing[]> = {};
      for (const t of stage.timings) (levels[String(t.level)] ??= []).push(t);
      const perLevel: Record<string, Summary> = {};
      for (const k of Object.keys(levels)) perLevel[k] = summarize(levels[k]);
      return { all: summarize(stage.timings), levels: perLevel };
    },

    /** Resolves when no tile is queued or drawing. */
    idle(): Promise<void> {
      return new Promise((resolve) => {
        const check = () => (stage.pending() === 0 ? resolve() : setTimeout(check, 50));
        check();
      });
    },

    /** Moves the camera every frame for `frames` frames and reports the frame intervals
     * and the time each frame took to draw. */
    bench(kind: "pan" | "zoom" = "pan", frames = 120) {
      return new Promise((resolve) => {
        const rect = stage.canvas.getBoundingClientRect();
        const times: number[] = [];
        const work: number[] = [];
        let last = 0;
        let i = 0;
        const step = (now: number) => {
          if (last) times.push(now - last);
          last = now;
          const t0 = performance.now();
          const c = stage.cam;
          if (kind === "pan") {
            stage.setCamera({ ...c, x: c.x + 12 / c.z, y: c.y + 4 / c.z });
          } else {
            const z = Math.min(MAX_ZOOM, Math.max(MIN_ZOOM, c.z * (i < frames / 2 ? 1.03 : 1 / 1.03)));
            const wx = c.x + rect.width / 2 / c.z;
            const wy = c.y + rect.height / 2 / c.z;
            stage.setCamera({ z, x: wx - rect.width / 2 / z, y: wy - rect.height / 2 / z });
          }
          stage.frame(now);
          work.push(performance.now() - t0);
          if (++i < frames) {
            requestAnimationFrame(step);
            return;
          }
          const s = [...times].sort((a, b) => a - b);
          const k = [...work].sort((a, b) => a - b);
          resolve({
            kind,
            frames,
            fps: round(1000 / (times.reduce((a, b) => a + b, 0) / times.length)),
            intervalP50: round(percentile(s, 0.5)),
            intervalP95: round(percentile(s, 0.95)),
            intervalMax: round(s[s.length - 1]),
            drawP50: round(percentile(k, 0.5)),
            drawMax: round(k[k.length - 1]),
          });
        };
        requestAnimationFrame(step);
      });
    },

    /** Each worker's engine memory and decoded images; the tile cache. */
    async memory() {
      const pool = stage.pool!;
      const per = await Promise.all(pool.slots.map((s) => pool.call(s, { type: "stats" })));
      const heap = (performance as Performance & { memory?: { usedJSHeapSize: number } }).memory;
      return {
        workers: per.map((p) => ({ memoryMB: round((p.memory as number) / 1048576), imagesMB: round((p.image_bytes as number) / 1048576), images: p.images })),
        tilesMB: round(stage.bytes / 1048576),
        tiles: stage.tiles.size,
        mainEngineMB: stage.engine ? round(stage.engine.memory.buffer.byteLength / 1048576) : 0,
        gpuTexturesMB: stage.gpu ? round(stage.gpu.stats.textureBytes / 1048576) : 0,
        jsHeapMB: heap ? round(heap.usedJSHeapSize / 1048576) : 0,
      };
    },

    /** Node `nodeId` drawn on the GPU at `scale` (read back) against the CPU engine's
     * export of it: the share of pixels within 2/255 and the largest difference, with
     * what the GPU drew and what fell back to the CPU. */
    async gpuCompare(nodeId: string, scale = 1) {
      const gpu = stage.gpu;
      const engine = stage.engine;
      if (!gpu || !engine) throw new Error("no GPU canvas");
      const pool = stage.pool!;
      const t0 = performance.now();
      const cpu = await pool.call(pool.slots[0], { type: "node", node: nodeId, scale, page: stage.page });
      const t1 = performance.now();
      const width = cpu.width as number;
      const height = cpu.height as number;
      const g = await gpu.renderNode(engine, nodeId, scale, width, height);
      const t2 = performance.now();
      const a = agreement(g.data, cpu.data as Uint8ClampedArray);
      const pg = stage.currentPage();
      const name = pg?.frames.find((f) => f.id === nodeId)?.name ?? "";
      return {
        node: nodeId,
        name,
        scale,
        size: [width, height],
        ...a,
        cpuMs: Math.round(t1 - t0),
        gpuMs: Math.round(t2 - t1),
        prims: g.stats.prims,
        fallbacks: g.stats.fallbacks,
        features: g.stats.features,
        reasons: g.stats.reasons,
      };
    },

    /** Where node `nodeId` drawn on the GPU differs from the CPU by more than 2/255: the
     * 32-pixel cells holding most such pixels (node pixels at `scale`), with a GPU and a
     * CPU pixel from each. */
    async gpuDiff(nodeId: string, scale = 1, cells = 12) {
      const gpu = stage.gpu;
      const engine = stage.engine;
      if (!gpu || !engine) throw new Error("no GPU canvas");
      const pool = stage.pool!;
      const cpu = await pool.call(pool.slots[0], { type: "node", node: nodeId, scale, page: stage.page });
      const width = cpu.width as number;
      const height = cpu.height as number;
      const g = await gpu.renderNode(engine, nodeId, scale, width, height);
      const c = cpu.data as Uint8ClampedArray;
      const counts = new Map<string, { n: number; worst: number; at: number }>();
      for (let i = 0; i < c.length; i += 4) {
        let d = 0;
        for (let k = 0; k < 4; k++) d = Math.max(d, Math.abs(g.data[i + k] - c[i + k]));
        if (d <= 2) continue;
        const p = i / 4;
        const key = `${Math.floor((p % width) / 32) * 32},${Math.floor(p / width / 32) * 32}`;
        const e = counts.get(key) ?? { n: 0, worst: 0, at: p };
        e.n++;
        if (d > e.worst) {
          e.worst = d;
          e.at = p;
        }
        counts.set(key, e);
      }
      const list = [...counts.entries()].sort((a, b) => b[1].n - a[1].n).slice(0, cells);
      return list.map(([cell, e]) => ({ cell, off: e.n, worst: e.worst, x: e.at % width, y: Math.floor(e.at / width), gpu: Array.from(g.data.subarray(e.at * 4, e.at * 4 + 4)), cpu: Array.from(c.subarray(e.at * 4, e.at * 4 + 4)) }));
    },

    /** Shadows by formula against shadows by passes, each against the CPU: over node
     * `nodeId` at `scale`, and over the pixels the formula shadows reach (outside
     * surfaces), the share within 2/255. */
    async shadowCheck(nodeId: string, scale = 1) {
      const gpu = stage.gpu;
      const engine = stage.engine;
      if (!gpu || !engine) throw new Error("no GPU canvas");
      const pool = stage.pool!;
      const cpu = await pool.call(pool.slots[0], { type: "node", node: nodeId, scale, page: stage.page });
      const width = cpu.width as number;
      const height = cpu.height as number;
      // Where the formula shadows draw (prims of feature 8 on the node's own target).
      engine.gpuFormula(true);
      const inShadow = new Uint8Array(width * height);
      const formula = await gpu.renderNode(engine, nodeId, scale, width, height, (hdr) => {
      const head = new Uint32Array(engine.memory.buffer, hdr, 59);
      const prims = new Float32Array(engine.memory.buffer, head[1], head[2] * 16);
      const primWords = new Uint32Array(engine.memory.buffer, head[1], head[2] * 16);
      const draws = new Uint32Array(engine.memory.buffer, head[9], head[10] * 8);
      let depth = 0;
      for (let i = 0; i < head[10]; i++) {
        const kind = draws[i * 8];
        if (kind === 2) depth++;
        else if (kind === 3) depth--;
        else if (kind === 0 && depth === 0) {
          for (let p = draws[i * 8 + 1]; p < draws[i * 8 + 1] + draws[i * 8 + 2]; p++) {
            if (primWords[p * 16 + 11] !== 8) continue;
            for (let y = Math.max(0, prims[p * 16 + 1]); y < Math.min(height, prims[p * 16 + 3]); y++) {
              for (let x = Math.max(0, prims[p * 16]); x < Math.min(width, prims[p * 16 + 2]); x++) inShadow[y * width + x] = 1;
            }
          }
        }
      }
      });
      engine.gpuFormula(false);
      const passes = await gpu.renderNode(engine, nodeId, scale, width, height);
      engine.gpuFormula(true);
      const c = cpu.data as Uint8ClampedArray;
      const score = (g: Uint8ClampedArray) => {
        let off = 0;
        let offShadow = 0;
        let shadowPixels = 0;
        let max = 0;
        for (let i = 0; i < c.length; i += 4) {
          let d = 0;
          for (let k = 0; k < 4; k++) d = Math.max(d, Math.abs(g[i + k] - c[i + k]));
          const s = inShadow[i / 4];
          shadowPixels += s;
          if (d > 2) {
            off++;
            offShadow += s;
          }
          if (s && d > max) max = d;
        }
        const pct = (a: number, n: number) => (n ? Math.round((1 - a / n) * 10000) / 100 : 100);
        return { within2: pct(off, c.length / 4), shadowWithin2: pct(offShadow, shadowPixels), shadowPixels, shadowMax: max };
      };
      return { node: nodeId, scale, formula: score(formula.data), passes: score(passes.data) };
    },

    /** `gpuCompare` for every top-level node of the page (or those whose names match
     * `filter`), with the total; logs a table. */
    async gpuReport(scale = 1, filter = "", maxPixels = 40e6) {
      const pg = stage.currentPage();
      if (!pg) throw new Error("no page");
      const rows: Record<string, unknown>[] = [];
      let off = 0;
      let pixels = 0;
      for (const f of pg.frames) {
        if (filter && !f.name.toLowerCase().includes(filter.toLowerCase())) continue;
        const w = (f.box[2] - f.box[0]) * scale;
        const h = (f.box[3] - f.box[1]) * scale;
        if (w * h > maxPixels || w < 1 || h < 1) continue;
        try {
          const r = await checks.gpuCompare(f.id, scale);
          off += r.off;
          pixels += r.pixels;
          rows.push({ name: r.name, node: r.node, size: r.size.join("x"), within2: r.within2, max: r.max, prims: r.prims, fallbacks: r.fallbacks, reasons: Object.entries(r.reasons).map(([k, v]) => `${k} ${v}`).join(", ") });
        } catch (err) {
          rows.push({ name: f.name, node: f.id, error: err instanceof Error ? err.message : String(err) });
        }
      }
      console.table(rows);
      return { scale, frames: rows.length, within2: pixels ? Math.round((1 - off / pixels) * 10000) / 100 : 100, rows };
    },

    /** Shows node `nodeId` fitted from nothing cached and resolves with the time (ms)
     * until it is fully sharp: on the GPU (`gpu`) or in CPU tiles. */
    async sharpTime(nodeId: string, gpu = true) {
      const pg = stage.currentPage()!;
      const f = pg.frames.find((x) => x.id === nodeId);
      if (!f) throw new Error(`${nodeId} is not a top-level node of this page`);
      stage.setGpu(gpu);
      stage.gpu?.clear();
      stage.clearTiles();
      stage.timings = [];
      const t0 = performance.now();
      stage.showRect(f.box[0], f.box[1], f.box[2], f.box[3]);
      await wait(50);
      for (;;) {
        if (stage.pending() === 0) break;
        await wait(10);
      }
      // One more frame so the last tiles show.
      await new Promise((r) => requestAnimationFrame(() => r(null)));
      return { node: nodeId, renderer: gpu ? "GPU" : "CPU", ms: Math.round(performance.now() - t0), gpu: stage.gpu ? { ...stage.gpu.stats } : null };
    },

    /** Frame rate and per-frame work zooming in and out (2% a frame) and panning, at
     * each zoom in `zooms` ("fit": the page fitted), centred on node `nodeId` (or the
     * page's middle). */
    async motion(zooms: (number | "fit")[] = ["fit", 0.1, 0.5, 1, 4], nodeId = "") {
      const rect = stage.canvas.getBoundingClientRect();
      const pg = stage.currentPage()!;
      const f = pg.frames.find((x) => x.id === nodeId);
      const loop = (n: number, move: (i: number) => void) =>
        new Promise<Record<string, number>>((resolve) => {
          const iv: number[] = [];
          const work: number[] = [];
          const scene: number[] = [];
          let last = 0;
          let i = 0;
          const step = (now: number) => {
            if (last) iv.push(now - last);
            last = now;
            move(i);
            const t0 = performance.now();
            stage.frame(now);
            work.push(performance.now() - t0);
            if (stage.gpu) scene.push(stage.gpu.stats.sceneMs);
            if (++i < n) {
              requestAnimationFrame(step);
              return;
            }
            const w = [...work].sort((a, b) => a - b);
            const sc = [...scene].sort((a, b) => a - b);
            const ivs = [...iv].sort((a, b) => a - b);
            resolve({
              fps: round(1000 / (iv.reduce((a, b) => a + b, 0) / iv.length)),
              intervalP50: round(percentile(ivs, 0.5)),
              intervalP95: round(percentile(ivs, 0.95)),
              frameP50: round(percentile(w, 0.5)),
              frameP95: round(percentile(w, 0.95)),
              sceneP50: round(percentile(sc, 0.5)),
            });
          };
          requestAnimationFrame(step);
        });
      const place = (z: number | "fit") => {
        if (z === "fit") return stage.fit();
        const cx = f ? (f.box[0] + f.box[2]) / 2 : stage.cam.x + rect.width / 2 / stage.cam.z;
        const cy = f ? Math.min(f.box[3], f.box[1] + 2000) : stage.cam.y + rect.height / 2 / stage.cam.z;
        stage.setCamera({ z, x: cx - rect.width / 2 / z, y: cy - rect.height / 2 / z });
      };
      const zoomMove = (i: number) => {
        const c = stage.cam;
        const z = c.z * (i < 60 ? 1.02 : 1 / 1.02);
        const wx = c.x + rect.width / 2 / c.z;
        const wy = c.y + rect.height / 2 / c.z;
        stage.cam = { z, x: wx - rect.width / 2 / z, y: wy - rect.height / 2 / z };
      };
      const panMove = (i: number) => {
        const c = stage.cam;
        const d = i < 60 ? 1 : -1;
        stage.cam = { ...c, x: c.x + (d * 8) / c.z, y: c.y + (d * 3) / c.z };
      };
      const out: Record<string, unknown> = {};
      // Only the loop's frames: arrivals and glyph follow-ups would draw more in between.
      const changed = stage.gpu?.onChange;
      for (const z of zooms) {
        place(z);
        await wait(2500);
        if (stage.gpu) stage.gpu.onChange = () => {};
        const zoom = await loop(120, zoomMove);
        if (stage.gpu && changed) stage.gpu.onChange = changed;
        place(z);
        await wait(2500);
        if (stage.gpu) stage.gpu.onChange = () => {};
        const pan = await loop(120, panMove);
        if (stage.gpu && changed) stage.gpu.onChange = changed;
        out[String(z)] = { zoom, pan };
      }
      return out;
    },

    /** Draws with the GPU (true) or the CPU tiles (false). */
    setGpu(on: boolean) {
      stage.setGpu(on);
    },

    /** Starts measuring afresh: no tiles, no timings. */
    reset() {
      stage.clearTiles();
      stage.timings = [];
      stage.requestDraw();
    },
  };
  (window as unknown as { viewer: typeof checks }).viewer = checks;
}
