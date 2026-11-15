// What the document worker and the shell share: node kinds, flag bits, sources.

export type Source = { kind: "file"; id: string } | { kind: "url"; base: string } | { kind: "fig"; url: string; wasm: string };

/** Node kinds by code, as `types` in a tree holds them. */
export const TYPES = ["frame", "group", "section", "component", "component-set", "instance", "rectangle", "ellipse", "line", "vector", "text", "star", "polygon", "boolean", "slice", "page", "other"];

/** Bits of a tree's `flags`. */
export const F = {
  visible: 1,
  locked: 2,
  /** Inside an instance (drawn from its main; shown purple). */
  inInstance: 4,
  mask: 8,
  clip: 16,
  /** Hidden by an ancestor. */
  hiddenAbove: 32,
  reverseZ: 64,
  /** Locked by an ancestor. */
  lockedAbove: 128,
  /** Inside a component (a main). */
  inComponent: 256,
  /** Filled with an image (the layers panel shows a picture). */
  image: 512,
  /** Auto layout by direction (the row's icon); its children are listed in flow order. */
  autoV: 1024,
  autoH: 2048,
  autoGrid: 4096,
} as const;

