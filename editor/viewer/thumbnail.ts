// A file's card picture: the first page's top-level nodes, fitted into a small landscape
// image over the page's background, drawn by the engine and encoded as PNG. Runs in a
// worker (OffscreenCanvas only encodes).

import type { Engine } from "./engine";

/** The card picture's size in pixels (4:3, twice the card's CSS size). */
export const THUMB_W = 480;
export const THUMB_H = 360;

const css = (c: number[]) => `rgb(${Math.round(c[0] * 255)},${Math.round(c[1] * 255)},${Math.round(c[2] * 255)})`;

/** Reads what a render draws before it draws (a document read in pieces: feed.ts). */
export type Prepare = (page: number, x: number, y: number, scale: number, w: number, h: number) => Promise<void>;

/** The PNG bytes, or null when the first page holds nothing to show. */
export async function thumbnail(e: Engine, prepare?: Prepare): Promise<Uint8Array | null> {
  const page = e.pages().pages[0];
  if (!page || !page.frames.length) return null;
  let x0 = Infinity;
  let y0 = Infinity;
  let x1 = -Infinity;
  let y1 = -Infinity;
  for (const f of page.frames) {
    x0 = Math.min(x0, f.box[0]);
    y0 = Math.min(y0, f.box[1]);
    x1 = Math.max(x1, f.box[2]);
    y1 = Math.max(y1, f.box[3]);
  }
  const bw = Math.max(1, x1 - x0);
  const bh = Math.max(1, y1 - y0);
  // A margin of a tenth around the nodes; small designs are not blown up past 2x.
  const scale = Math.min((THUMB_W * 0.9) / bw, (THUMB_H * 0.9) / bh, 2);
  const w = Math.max(1, Math.min(THUMB_W, Math.ceil(bw * scale)));
  const h = Math.max(1, Math.min(THUMB_H, Math.ceil(bh * scale)));
  if (prepare) await prepare(0, x0, y0, scale, w, h);
  const px = e.renderTile(0, x0, y0, scale, w, h, 0);
  const bitmap = await createImageBitmap(new ImageData(px, w, h));
  const canvas = new OffscreenCanvas(THUMB_W, THUMB_H);
  const ctx = canvas.getContext("2d");
  if (!ctx) return null;
  ctx.fillStyle = css(page.background ?? [0.96, 0.96, 0.96]);
  ctx.fillRect(0, 0, THUMB_W, THUMB_H);
  ctx.drawImage(bitmap, Math.round((THUMB_W - w) / 2), Math.round((THUMB_H - h) / 2));
  bitmap.close();
  const blob = await canvas.convertToBlob({ type: "image/png" });
  return new Uint8Array(await blob.arrayBuffer());
}
