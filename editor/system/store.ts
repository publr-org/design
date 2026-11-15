// The design system canvas's store: what its chrome shows (the left panel, the item
// panel, the drag's ghost, the sampling dialog) and the one way the data changes,
// `change`: the next document is drawn into the canvas as one engine step (the data on
// the page and the scene's changes together), kept in OPFS, and shown in the panels.
// Undo and redo are the engine's; the data comes back from the page after them.
//
// Glue, not UI: the chrome (SystemPanel, ItemPanel, SampleDialog) renders `sys`.

import { Publr } from "publr-jsx";
import { toast } from "../app/route";
import { listFiles, listProjects, servedEdits } from "../home/store";
import type { DsCanvas } from "./canvas";
import { ensureSeed, loadDoc, loadWhy, saveDoc, SEEDS } from "./persist";
import type { Why } from "./persist";
import { SECTION_OF } from "./model";
import type { Doc, ItemRef, SectionKey } from "./model";

export type Focus = "system" | "free";

export const sys = Publr.reactive({
  /** The project whose system shows ("" none). */
  project: "",
  projectName: "",
  /** "Opening…", an error, or "" once drawn. */
  status: "Opening the design system…",
  ready: false,
  /** What the canvas shows: everything, or one section. */
  section: "overview" as "overview" | SectionKey,
  /** The side the keys and the right panel follow. */
  focus: "system" as Focus,
  /** The selected item, or the selected section ("" none). */
  selected: null as ItemRef | null,
  selectedSection: "" as SectionKey | "",
  /** The document as the panels read it (a copy, replaced on every change). */
  doc: null as Doc | null,
  /** The blocks Primitive blocks lists. */
  blocks: [] as { type: string; label: string; category: string }[],
  /** The faces here, by family: [weight, face name]. */
  faces: {} as Record<string, [number, string][]>,
  /** The files that can open beside: the project's, then Drafts. */
  files: [] as { id: string; name: string; where: string }[],
  /** The design system's changes saved ("saving", "saved", ""). */
  saved: "",
  /** Bring in's evidence by item (`color:<token>`), shown for the selected token. */
  why: {} as Record<string, Why>,
  /** The selection in the reference, summed up for the right panel. */
  found: { count: 0, rows: [] as { kind: string; label: string; detail: string; found: number; fresh: number }[] },
  /** A drag carried between the canvases: the pill under the pointer. */
  ghost: { show: false, x: 0, y: 0, text: "", swatch: "", ok: true },
});

let canvas: DsCanvas | null = null;
let current: Doc | null = null;

export const dsCanvas = () => canvas;
export const currentDoc = () => current;

/** The canvas the data draws into (DsCanvas calls it once it is up). */
export function attachCanvas(c: DsCanvas): void {
  canvas = c;
}

function show(doc: Doc): void {
  current = doc;
  sys.doc = structuredClone(doc);
  // A selection whose item went (removed, or an undo took it back) goes too.
  if (sys.selected && !canvas?.hasItem(sys.selected)) sys.selected = null;
}

let saveTimer = 0;
function persist(): void {
  const project = sys.project;
  const doc = current;
  if (!project || !doc) return;
  sys.saved = "saving";
  window.clearTimeout(saveTimer);
  saveTimer = window.setTimeout(() => {
    void saveDoc(project, doc).then(() => (sys.saved = "saved"));
  }, 300);
}

/** The next document: drawn, kept and shown (one undo step), the selection after it. */
export function change(next: Doc, select: ItemRef | null | undefined = undefined): void {
  if (!canvas || !current) return;
  if (select !== undefined) sys.selected = select;
  canvas.apply(next, sys.selected);
  show(next);
  persist();
}

/** Applies `fn` to the system (a builder operation) and draws the result. */
export function changeSystem(fn: (s: Doc["system"]) => Doc["system"], select?: ItemRef | null): void {
  if (!current) return;
  change({ ...current, system: fn(current.system) }, select);
}

/** After undo or redo: the data as the page holds it now. */
export function restored(doc: Doc, selection: ItemRef | null): void {
  sys.selected = selection;
  show(doc);
  persist();
}

// ------------------------------------------------------------ steps

let stepOpen = false;

/** A scrub or a drag in a panel: the changes until `endStep` undo as one. */
export function beginStep(): void {
  const ed = canvas?.editing;
  if (!ed || stepOpen) return;
  ed.begin();
  stepOpen = true;
}

export function endStep(): void {
  const ed = canvas?.editing;
  if (!ed || !stepOpen) return;
  stepOpen = false;
  ed.commit();
}

/** Ends the open step by undoing it (Escape during a scrub). */
export function cancelStep(): void {
  const ed = canvas?.editing;
  if (!ed || !stepOpen) return;
  stepOpen = false;
  ed.cancel();
}

/** A field's phase: a typed value is a step of its own, a scrub one step from start
 * to end. */
export function phased(phase: string, apply: () => void): void {
  if (phase === "start") beginStep();
  if (phase === "cancel") return cancelStep();
  apply();
  if (phase === "end") endStep();
}

// ------------------------------------------------------------ the selection and the view

export function selectItem(ref: ItemRef | null): void {
  sys.selected = ref;
  sys.selectedSection = ref ? SECTION_OF[ref.kind] : "";
  sys.focus = "system";
  canvas?.request();
}

export function selectSection(key: SectionKey | ""): void {
  sys.selected = null;
  sys.selectedSection = key;
  sys.focus = "system";
  canvas?.request();
}

/** The left panel's category: the canvas narrows to it (Overview: everything). */
export function showSection(key: "overview" | SectionKey): void {
  sys.section = key;
  sys.focus = "system";
  if (key !== "overview") selectSection(key);
  canvas?.narrow(key === "overview" ? null : key, true);
}

export function setFocus(side: "system" | "free"): void {
  if (sys.focus !== side) sys.focus = side;
}

// ------------------------------------------------------------ opening

/** Opens project `project`'s design system (the canvas draws once it is up). */
export async function openSystem(project: string): Promise<Doc | null> {
  sys.project = project;
  sys.ready = false;
  sys.status = "Opening the design system…";
  const projects = await listProjects();
  sys.projectName = projects.find((p) => p.id === project)?.name ?? "";
  void refreshFiles();
  const [doc, why] = await Promise.all([loadDoc(project), loadWhy(project)]);
  sys.why = why;
  if (!doc) {
    sys.status = "This project has no design system yet.";
    return null;
  }
  current = doc;
  sys.doc = structuredClone(doc);
  return doc;
}

/** The canvas drew the document. */
export function opened(): void {
  sys.ready = true;
  sys.status = "";
}

export function failed(message: string): void {
  sys.status = message;
}

export async function refreshFiles(): Promise<void> {
  const files = (await listFiles()).filter((f) => !f.trashed);
  const mine = files.filter((f) => f.project === sys.project);
  const rest = files.filter((f) => f.project !== sys.project);
  const { servedDoc } = await import("../viewer/loader");
  const served = await servedDoc();
  // Its edits are kept in this browser (the server keeps the document as it is).
  const edited = served?.kind === "pubd" ? !!(await servedEdits(served.name)) : false;
  sys.files = [
    ...mine.map((f) => ({ id: f.id, name: f.name, where: sys.projectName })),
    ...rest.map((f) => ({ id: f.id, name: f.name, where: f.project ? "" : "Drafts" })),
    ...(served ? [{ id: "served", name: served.name, where: edited ? "pe view · edited here" : "pe view" }] : []),
  ];
}

/** The address `/?system` (`/?system=untitled-ui` for that demo): the project Bring
 * in seeded, on its design system tab. Returns the address to go to. */
export async function seededAddress(key = "caraway"): Promise<string> {
  const seed = await ensureSeed(SEEDS[key] ? key : "caraway");
  const { SERVED_ID } = await import("../home/store");
  pendingReference = seed.leftovers || SERVED_ID;
  return `/system/${seed.project}`;
}

/** The reference a demo opens with the first time (its leftovers, or what `pe view`
 * serves). */
let pendingReference = "";
export const firstReference = () => pendingReference;

/** The demos Bring in seeded, for the project menu. */
export async function demoProjects(): Promise<{ key: string; name: string; project: string }[]> {
  const { readJson, root } = await import("../home/store");
  const d = await (await root()).getDirectoryHandle("design-systems", { create: true });
  const out: { key: string; name: string; project: string }[] = [];
  for (const [key, spec] of Object.entries(SEEDS)) {
    const kept = await readJson<{ project: string }>(d, spec.file).catch(() => null);
    out.push({ key, name: spec.name, project: kept?.project ?? "" });
  }
  return out;
}

/** The moodboard: the project's "Board" file, made on first use, in its tab. */
export async function openMoodboard(): Promise<void> {
  const { createEmpty, updateMeta } = await import("../home/store");
  await refreshFiles();
  let board = (await listFiles()).find((f) => f.project === sys.project && f.name === "Board" && !f.trashed);
  if (!board) {
    const meta = await createEmpty(sys.project);
    board = (await updateMeta(meta.id, { name: "Board" })) ?? meta;
    await refreshFiles();
    toast("Made the project's board", 2500);
  }
  const { showFileTab } = await import("./workspace");
  showFileTab(board.id);
}

// The console's (and the tests') look at the data: `pdSystemDoc()`.
if (typeof window !== "undefined") (window as unknown as { pdSystemDoc?: () => Doc | null }).pdSystemDoc = () => current;
