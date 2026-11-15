// Where a project's design system lives in the browser, beside the files (OPFS):
//
//   design-systems/<project>.json   { doc: Doc, saved }: the builder's DesignSystem and
//                                   the primitive blocks' components
//   design-systems/<project>.why.json  { [item]: Why }: Bring in's evidence per token
//                                   (the variable, what binds it, confidence, reason),
//                                   shown for the selected token, never on the canvas
//   design-systems/<project>.workspace.json  the tabs open, the reference and its
//                                   picture-in-picture (workspace.ts)
//   design-systems/seed.json        { project, leftovers, version }: the Caraway demo
//   design-systems/seed-<key>.json  the same for the other demos (Untitled UI)
//
// A seed is Bring in's run on a design file: the system it derived
// (`/seed/<key>/design-system.json`, the `.pubd`'s document with
// `data.publr.designSystem` on its page), its plan (`plan.json`, read for the evidence)
// and, for Caraway, the leftovers canvas (`leftovers.json`), served beside the app. A
// seeded project is made once: a new project, a new file, a new entry here; a newer run
// of Bring in (the demo's `version` in SEEDS) replaces only the seeded project's system
// and evidence.
//
// Glue, not UI.

import { createProject, fileDir, freshMeta, getMeta, listProjects, newId, readJson, root, saveMeta, writeJson } from "../home/store";
import { svgFromPubd } from "./icons";
import { completeDoc } from "./model";
import type { Doc } from "./model";
import type { DesignSystem, IconDefinition } from "./model";

type N = Record<string, unknown>;

async function dir(): Promise<FileSystemDirectoryHandle> {
  return (await root()).getDirectoryHandle("design-systems", { create: true });
}

/** The project's design system, or null when it has none yet. */
export async function loadDoc(project: string): Promise<Doc | null> {
  const stored = await readJson<{ doc: Partial<Doc> }>(await dir(), `${project}.json`);
  return stored?.doc ? completeDoc(stored.doc) : null;
}

let saving: Promise<void> = Promise.resolve();

/** Keeps the project's design system (writes queue up in order). */
export function saveDoc(project: string, doc: Doc): Promise<void> {
  const copy = structuredClone(doc);
  saving = saving.then(async () => writeJson(await dir(), `${project}.json`, { doc: copy, saved: Date.now() })).catch((err) => console.error("design system: not saved", err));
  return saving;
}

/** Where a demo's reference opens first: its leftovers file, or the document `pe view`
 * serves. */
export type Seed = { project: string; leftovers: string; version?: number };

/** Why a token is in the system, as Bring in's plan says. */
export type Why = { variable: string; evidence: string; confidence: number | null; reason: string };

/** The demos: Bring in's run on Caraway's design system file and on Untitled UI. */
export const SEEDS: Record<string, { file: string; base: string; name: string; leftovers: boolean; version: number }> = {
  caraway: { file: "seed.json", base: "/seed/caraway/", name: "Caraway", leftovers: true, version: 3 },
  "untitled-ui": { file: "seed-untitled-ui.json", base: "/seed/untitled-ui/", name: "Untitled UI", leftovers: false, version: 4 },
};

/** Bring in's evidence by item (`color:<token>`, `role:<key>`, `type:<key>`, ...). */
function whyOf(plan: N): Record<string, Why> {
  const out: Record<string, Why> = {};
  const put = (key: string, x: N | undefined) => {
    if (!x || (!x.evidence && !x.reason)) return;
    const vars = x.variables && typeof x.variables === "object" ? Object.values(x.variables as N).filter((v): v is string => typeof v === "string") : [];
    out[key] = {
      variable: [typeof x.variable === "string" ? x.variable : "", ...vars].filter(Boolean).join("\n"),
      evidence: String(x.evidence ?? ""),
      confidence: typeof x.confidence === "number" ? x.confidence : null,
      reason: String(x.reason ?? ""),
    };
  };
  const list = (v: unknown) => (Array.isArray(v) ? (v as N[]) : []);
  const colors = (plan.colors as N) ?? {};
  for (const c of list(colors.palette)) put(`color:${c.token}`, c);
  for (const r of list(colors.roles)) put(`role:${r.role}`, r);
  for (const f of list(plan.fonts)) put(`font:${f.token}`, f);
  for (const t of list(plan.typeScale)) put(`type:${t.key}`, t);
  for (const t of list(plan.spacing)) put(`spacing:${t.token}`, t);
  for (const t of list(plan.radii)) put(`radius:${t.token}`, t);
  for (const t of list(plan.shadows)) put(`shadow:${t.token}`, t);
  for (const b of list(plan.breakpoints)) put(`breakpoint:${b.key}`, b);
  for (const i of list(plan.icons)) put(`icon:${i.name}`, i);
  return out;
}

/** The project's evidence (empty when it has none). */
export async function loadWhy(project: string): Promise<Record<string, Why>> {
  return (await readJson<Record<string, Why>>(await dir(), `${project}.why.json`)) ?? {};
}

async function fetchJson(url: string): Promise<N> {
  const r = await fetch(url);
  if (!r.ok) throw new Error(`${url}: ${r.status}`);
  return (await r.json()) as N;
}

/** The icons Bring in carried over, as the builder keeps them: SVG from the drawings on
 * the page's Icons section (the plan lists their names). */
function seedIcons(page: N, names: string[]): IconDefinition[] {
  const found = new Map<string, N>();
  const walk = (n: N) => {
    const kids = (n.children as N[]) ?? [];
    // A tile: a frame named for the icon holding the "icon" frame with the drawing.
    if (typeof n.name === "string" && names.includes(n.name) && !found.has(n.name)) {
      const holder = kids.find((k) => k.name === "icon");
      const drawing = ((holder?.children as N[]) ?? [])[0];
      if (drawing) found.set(n.name, drawing);
    }
    kids.forEach(walk);
  };
  walk(page);
  return names.flatMap((name) => {
    const n = found.get(name);
    if (!n) return [];
    return [{ name, label: String(n.name ?? name), category: "Brought in", svg: svgFromPubd(n) }];
  });
}

/** The system a seed's run derived, as the canvas keeps it. */
function seededDoc(system: N): Doc {
  const page = ((system.pages as N[]) ?? [])[0] ?? {};
  const data = ((page.data as N)?.publr as N)?.designSystem as Partial<DesignSystem> & { icons?: unknown };
  if (!data) throw new Error("the seed has no design system");
  const iconNames = (data.icons as unknown[] | undefined)?.filter((x): x is string => typeof x === "string") ?? [];
  return completeDoc({ system: { ...data, icons: seedIcons(page, iconNames) } as Partial<DesignSystem> });
}

/** Demo `key`'s project (and, for Caraway, its leftovers file), made on first use; a
 * newer run replaces the seeded system and its evidence. */
export async function ensureSeed(key = "caraway"): Promise<Seed> {
  const spec = SEEDS[key] ?? SEEDS.caraway;
  const d = await dir();
  const kept = await readJson<Seed>(d, spec.file);
  const projects = await listProjects();
  const keptProject = !!kept && projects.some((p) => p.id === kept.project);
  const keptLeftovers = !!kept && (!spec.leftovers || !!(await getMeta(kept.leftovers)));
  if (kept && keptProject && keptLeftovers && kept.version === spec.version && (await loadDoc(kept.project))) return kept;

  const [system, plan] = await Promise.all([fetchJson(`${spec.base}design-system.json`), fetchJson(`${spec.base}plan.json`).catch(() => ({}) as N)]);
  const doc = seededDoc(system);
  const project = kept && keptProject ? kept.project : (await createProject(spec.name)).id;
  let leftovers = kept && keptLeftovers ? kept.leftovers : "";
  if (spec.leftovers && !leftovers) {
    const lo = await fetchJson(`${spec.base}leftovers.json`);
    const id = newId();
    const fd = await fileDir(id, true);
    if (!fd) throw new Error("cannot write the leftovers file");
    await writeJson(fd, "document.json", lo);
    await saveMeta(freshMeta(id, String(lo.name ?? "Leftovers"), "pubd", project));
    leftovers = id;
  }
  await saveDoc(project, doc);
  await writeJson(d, `${project}.why.json`, whyOf(plan));
  const seed: Seed = { project, leftovers, version: spec.version };
  await writeJson(d, spec.file, seed);
  return seed;
}
