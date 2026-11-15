// Colours as the design system canvas reads them: Pubd paint colours (`#rrggbb`,
// `#rrggbbaa`, `[r, g, b(, a)]` in 0..1) and the builder's CSS values, to and from hex,
// and how far apart two colours look (CIEDE2000, as Bring in folds them).
//
// Glue, not UI.

import { parseColorToOklch } from "../../../editor/design/model/colors";

export type Rgba = { r: number; g: number; b: number; a: number };

const clamp = (v: number) => Math.min(1, Math.max(0, v));

/** A Pubd colour value, or null when it is none. */
export function pubdColor(v: unknown): Rgba | null {
  if (Array.isArray(v) && v.length >= 3) return { r: Number(v[0]), g: Number(v[1]), b: Number(v[2]), a: v.length > 3 ? Number(v[3]) : 1 };
  if (typeof v === "string") return hexColor(v);
  if (v && typeof v === "object") {
    const o = v as Record<string, unknown>;
    if (typeof o.r === "number") return { r: o.r, g: Number(o.g), b: Number(o.b), a: typeof o.a === "number" ? o.a : 1 };
  }
  return null;
}

/** `#rgb`, `#rrggbb` or `#rrggbbaa`; null otherwise. */
export function hexColor(text: string): Rgba | null {
  const m = /^#?([\da-f]{3}|[\da-f]{6}|[\da-f]{8})$/i.exec(text.trim());
  if (!m) return null;
  const h = m[1].length === 3 ? m[1].replace(/./g, (c) => c + c) : m[1];
  const at = (i: number) => parseInt(h.slice(i, i + 2), 16) / 255;
  return { r: at(0), g: at(2), b: at(4), a: h.length === 8 ? at(6) : 1 };
}

const byte = (v: number) =>
  Math.round(clamp(v) * 255)
    .toString(16)
    .padStart(2, "0");

/** `#rrggbb`, with the alpha (`#rrggbbaa`) when it is not opaque. */
export function toHex(c: Rgba, alpha = true): string {
  const base = `#${byte(c.r)}${byte(c.g)}${byte(c.b)}`;
  return alpha && c.a < 0.999 ? `${base}${byte(c.a)}` : base;
}

/** A CSS colour the builder holds (`#…`, `rgb()`, `oklch()`, …) as RGBA; null when it
 * cannot be read. */
export function cssColor(value: string): Rgba | null {
  const hex = hexColor(value);
  if (hex) return hex;
  const o = parseColorToOklch(value, false);
  if (!o) return null;
  // OKLCH to sRGB.
  const a = o.c * Math.cos((o.h * Math.PI) / 180);
  const b = o.c * Math.sin((o.h * Math.PI) / 180);
  const l_ = o.l + 0.3963377774 * a + 0.2158037573 * b;
  const m_ = o.l - 0.1055613458 * a - 0.0638541728 * b;
  const s_ = o.l - 0.0894841775 * a - 1.291485548 * b;
  const l = l_ ** 3;
  const m = m_ ** 3;
  const s = s_ ** 3;
  const gamma = (x: number) => (x <= 0.0031308 ? 12.92 * x : 1.055 * x ** (1 / 2.4) - 0.055);
  return {
    r: clamp(gamma(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s)),
    g: clamp(gamma(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s)),
    b: clamp(gamma(-0.0041960863 * l - 0.7034186147 * m + 1.707614701 * s)),
    a: 1,
  };
}

/** The relative luminance (to pick a line around near-white swatches). */
export const luminance = (c: Rgba) => 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b;

type Lab = { l: number; a: number; b: number };

function lab(c: Rgba): Lab {
  const lin = (v: number) => (v <= 0.04045 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4);
  const R = lin(c.r);
  const G = lin(c.g);
  const B = lin(c.b);
  const x = (0.4124564 * R + 0.3575761 * G + 0.1804375 * B) / 0.95047;
  const y = 0.2126729 * R + 0.7151522 * G + 0.072175 * B;
  const z = (0.0193339 * R + 0.119192 * G + 0.9503041 * B) / 1.08883;
  const d = 6 / 29;
  const f = (t: number) => (t > d * d * d ? Math.cbrt(t) : t / (3 * d * d) + 4 / 29);
  return { l: 116 * f(y) - 16, a: 500 * (f(x) - f(y)), b: 200 * (f(y) - f(z)) };
}

const rad = (x: number) => (x * Math.PI) / 180;
const deg = (x: number) => (x * 180) / Math.PI;

/** CIEDE2000: under 1 nobody sees it, under 2 only side by side. */
export function deltaE(p: Rgba, q: Rgba): number {
  const x = lab(p);
  const y = lab(q);
  const c1 = Math.hypot(x.a, x.b);
  const c2 = Math.hypot(y.a, y.b);
  const cm7 = ((c1 + c2) / 2) ** 7;
  const g = 0.5 * (1 - Math.sqrt(cm7 / (cm7 + 25 ** 7)));
  const a1 = (1 + g) * x.a;
  const a2 = (1 + g) * y.a;
  const c1p = Math.hypot(a1, x.b);
  const c2p = Math.hypot(a2, y.b);
  const h1 = a1 === 0 && x.b === 0 ? 0 : (deg(Math.atan2(x.b, a1)) + 360) % 360;
  const h2 = a2 === 0 && y.b === 0 ? 0 : (deg(Math.atan2(y.b, a2)) + 360) % 360;
  const dl = y.l - x.l;
  const dc = c2p - c1p;
  let dh = 0;
  if (c1p * c2p !== 0) {
    dh = h2 - h1;
    if (dh > 180) dh -= 360;
    else if (dh < -180) dh += 360;
  }
  const dH = 2 * Math.sqrt(c1p * c2p) * Math.sin(rad(dh / 2));
  const lm = (x.l + y.l) / 2;
  const cpm = (c1p + c2p) / 2;
  let hm = h1 + h2;
  if (c1p * c2p !== 0) {
    if (Math.abs(h1 - h2) > 180) hm = h1 + h2 < 360 ? hm + 360 : hm - 360;
    hm /= 2;
  }
  const t = 1 - 0.17 * Math.cos(rad(hm - 30)) + 0.24 * Math.cos(rad(2 * hm)) + 0.32 * Math.cos(rad(3 * hm + 6)) - 0.2 * Math.cos(rad(4 * hm - 63));
  const dtheta = 30 * Math.exp(-(((hm - 275) / 25) ** 2));
  const cpm7 = cpm ** 7;
  const rc = 2 * Math.sqrt(cpm7 / (cpm7 + 25 ** 7));
  const lm50 = (lm - 50) ** 2;
  const sl = 1 + (0.015 * lm50) / Math.sqrt(20 + lm50);
  const sc = 1 + 0.045 * cpm;
  const sh = 1 + 0.015 * cpm * t;
  const rt = -Math.sin(rad(2 * dtheta)) * rc;
  const a = dl / sl;
  const b = dc / sc;
  const c = dH / sh;
  return Math.sqrt(a * a + b * b + c * c + rt * b * c);
}
