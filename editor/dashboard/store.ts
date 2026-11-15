// The dashboard's store: everything the chrome draws, as plain values. The modules that
// know when something changed (data.ts, view.ts, buildup.ts) write here; the PTSX parts
// only read.
import { Publr } from "publr-jsx";

/** One reference export, as `/api/state` lists it. */
export type Item = {
  file: string;
  node: string;
  name: string;
  scale: number;
  named_scale: number;
  width: number;
  height: number;
  nodes: number;
  top: string;
  top_name: string;
  depth: number;
};

/** `/api/state`. */
export type ServerState = {
  started: number;
  doc: string;
  items: Item[];
};

/** `/api/score/<file>`. */
export type Score = {
  file: string;
  pixels: number;
  mean: number;
  within2: number;
  within16: number;
  non_text_within2: number;
  visual: number;
  ms: number;
};

/** `/api/step/<file>?upto=N`. */
export type Step = {
  drawn: number;
  node: { id: string; name: string; type: string } | null;
  bounds: [number, number, number, number];
};

/** How a score reads: good (>= 99), amber (>= 95), bad, or not scored yet. */
export type Tone = "good" | "warn" | "bad" | "none";

/** One export of a node: its scale, size and score. */
export type RowView = {
  file: string;
  scale: string;
  size: string;
  badge: string;
  tone: Tone;
  title: string;
  selected: boolean;
};

/** One node with exports, indented by its depth under the frame. */
export type GroupView = {
  node: string;
  name: string;
  indent: number;
  rows: RowView[];
};

/** One top-level frame: its header, and its nodes while open. */
export type SectionView = {
  top: string;
  name: string;
  open: boolean;
  current: boolean;
  count: string;
  badge: string;
  tone: Tone;
  groups: GroupView[];
};

/** One number in the top bar: `visual 99.12%`. */
export type Num = {
  label: string;
  value: string;
  unit: string;
};

export type Mode = "side" | "swipe" | "flicker" | "build";

export const MODES: { key: Mode; label: string; shortcut: string }[] = [
  { key: "side", label: "Side by side", shortcut: "1" },
  { key: "swipe", label: "Swipe", shortcut: "2" },
  { key: "flicker", label: "Flicker", shortcut: "3" },
  { key: "build", label: "Build-up", shortcut: "4" },
];

export const ZOOMS: { key: string; label: string }[] = [
  { key: "fit", label: "Fit" },
  { key: "1", label: "1:1" },
  { key: "2", label: "2:1" },
  { key: "4", label: "4:1" },
];

/** The pixel inspector's line: where the pointer is and both colours under it. */
export type Inspect = {
  state: "idle" | "outside" | "pixel";
  at: string;
  figma: string;
  figmaColor: string;
  ours: string;
  oursColor: string;
  diff: string;
  diffOk: boolean;
};

export const state = Publr.reactive({
  doc: "loading",
  /** The pixel-weighted visual score of everything scored. */
  total: "-",
  totalTone: "none" as Tone,
  totalNote: "pixels within 2/255",
  sections: [] as SectionView[],

  /** The selected export. */
  file: "",
  title: "-",
  width: 0,
  height: 0,
  scored: false,
  nums: [] as Num[],

  mode: "side" as Mode,
  /** Counts layouts: each one draws fresh panes, so no image of the last export lingers. */
  shown: 0,
  refSrc: "",
  oursSrc: "",
  diffSrc: "",

  /** The view every pane shares. */
  transform: "",
  pixelated: false,
  zoomLabel: "",
  zoomKey: "fit",
  /** Swipe: the divider's x in the pane and the cut of our image, in its pixels. */
  dividerLeft: "50%",
  oursClip: "",
  /** Flicker: which image shows, and whether it is held. */
  flickerRef: true,
  flickerPaused: false,

  /** Build-up: the step shown, the node count, and what the step drew. */
  step: 0,
  nodes: 0,
  playing: false,
  busy: false,
  stepDrawn: "",
  stepNode: "",
  stepWhere: "",
  stepNote: "",
  hlShown: false,
  hlStyle: "",

  inspect: {
    state: "idle",
    at: "",
    figma: "",
    figmaColor: "",
    ours: "",
    oursColor: "",
    diff: "",
    diffOk: true,
  } as Inspect,

  live: true,
  toast: "",
  toastShown: false,
});

/** The pane area, measured for fitting and swiping. */
export const panesHost = Publr.ref();
