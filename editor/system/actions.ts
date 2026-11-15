// What the design system canvas and its panels ask: add, remove and reorder items, and a
// token carried out onto a layer of the canvas beside. Each is one change of the data
// (store.ts `change`): one undo step, drawn in the same frame.
//
// Glue, not UI.

import { select as selectFree, targetAt } from "../design/store";
import { viewerEditing, viewerStage } from "../viewer/Viewer.ptsx";
import { cssColor, toHex } from "./color";
import {
  addBreakpoint,
  addContainer,
  addEntry,
  addFont,
  addScaleToken,
  containers,
  dropFont,
  entryFamily,
  fontRoles,
  newRole,
  removeBreakpoint,
  removeContainer,
  removeIcon,
  removeRole,
  removeScaleToken,
  removeStyle,
  reorderContainers,
  reorderIcons,
  reorderRoles,
  reorderTokens,
  reorderTypeScale,
  resolveValue,
  roleColor,
  scaleTokens,
  semanticRoles,
  styleBreakpoints,
  tokenLabel,
  fonts as fontTokens,
  moved,
} from "./model";
import type { DesignSystem, ItemKind, ItemRef } from "./model";
import { cssLengthPx } from "../../../editor/design/model/system";
import { scaleValue } from "../../../editor/design/model/typescale";
import { shadowEffects } from "./scene";
import { change, changeSystem, currentDoc, dsCanvas, sys } from "./store";

// ------------------------------------------------------------ adding and removing

/** An "+ Add" chip: a new item of its kind, selected. */
export function addFromChip(kind: ItemKind): void {
  const doc = currentDoc();
  if (!doc) return;
  const s = doc.system;
  if (kind === "color" || kind === "spacing" || kind === "radius" || kind === "shadow") {
    const values = { color: "#8a8a93", spacing: "8px", radius: "8px", shadow: "0px 4px 12px 0px #0000001f" };
    const r = addScaleToken(s, kind, kind === "color" ? "new colour" : "new", values[kind]);
    change({ ...doc, system: r.system }, { kind, key: r.name });
  } else if (kind === "font") {
    const have = new Set(fontTokens(s).map((t) => t.name));
    const family = Object.keys(sys.faces).find((f) => !have.has(`font-${f.toLowerCase().replace(/[^a-z0-9]+/g, "-")}`)) ?? "Inter";
    const r = addFont(s, family, "sans-serif");
    if (typeof r !== "string") change({ ...doc, system: r.system }, { kind, key: r.token });
  } else if (kind === "container") {
    const r = addContainer(s);
    change({ ...doc, system: r.system }, { kind, key: r.key });
  } else if (kind === "role") {
    const r = newRole(s, "New role");
    if (r.key) change({ ...doc, system: r.system }, { kind, key: r.key });
  } else if (kind === "type") {
    const role = fontRoles(s)[0]?.key ?? "body";
    const r = addEntry(s, "New style", { fontRole: role, size: "16px", lineHeight: "24px" });
    if (r.key) change({ ...doc, system: r.system }, { kind, key: r.key });
  } else if (kind === "breakpoint") {
    const list = styleBreakpoints(s);
    const last = cssLengthPx(list[list.length - 1]?.viewport ?? "1024px") ?? 1024;
    let n = list.length;
    while (list.some((b) => b.key === `bp-${n}`)) n++;
    const r = addBreakpoint(s, `bp-${n}`, `${Math.round(last + 256)}`, "desktop");
    if (!r.error) change({ ...doc, system: r.system }, { kind, key: `bp-${n}` });
  }
}

/** Removes an item (what pointed at it keeps its value). */
export function removeItem(ref: ItemRef): void {
  const doc = currentDoc();
  if (!doc) return;
  const s = doc.system;
  let next: DesignSystem = s;
  switch (ref.kind) {
    case "color":
    case "spacing":
    case "radius":
    case "shadow":
      next = removeScaleToken(s, ref.key);
      break;
    case "font":
      next = dropFont(s, ref.key);
      break;
    case "icon":
      next = removeIcon(s, ref.key);
      break;
    case "container":
      next = removeContainer(s, ref.key);
      break;
    case "role":
      next = removeRole(s, ref.key);
      break;
    case "type":
      next = removeStyle(s, ref.key);
      break;
    case "breakpoint":
      if (ref.key === "base") return;
      next = removeBreakpoint(s, ref.key);
      break;
    case "block": {
      const primitives = { ...doc.primitives };
      delete primitives[ref.key];
      change({ ...doc, primitives });
      return;
    }
    default:
      return;
  }
  if (next !== s) change({ ...doc, system: next }, null);
}

/** Whether an item can be removed. */
export const removable = (ref: ItemRef, doc = currentDoc()) => ref.kind !== "fontRole" && !(ref.kind === "breakpoint" && ref.key === "base") && (ref.kind !== "block" || !!doc?.primitives[ref.key]);

/** Moves an item of a list from `from` to `to`. */
export function reorder(ref: ItemRef, from: number, to: number): void {
  const doc = currentDoc();
  if (!doc) return;
  const s = doc.system;
  if (ref.kind === "color" || ref.kind === "spacing" || ref.kind === "radius" || ref.kind === "shadow") {
    changeSystem(
      (x) =>
        reorderTokens(
          x,
          moved(
            scaleTokens(x, ref.kind as "color").map((t) => t.name),
            from,
            to,
          ),
        ),
      ref,
    );
  } else if (ref.kind === "font")
    changeSystem(
      (x) =>
        reorderTokens(
          x,
          moved(
            fontTokens(x).map((t) => t.name),
            from,
            to,
          ),
        ),
      ref,
    );
  else if (ref.kind === "icon") changeSystem((x) => reorderIcons(x, from, to), ref);
  else if (ref.kind === "container") changeSystem((x) => reorderContainers(x, from, to), ref);
  else if (ref.kind === "role") changeSystem((x) => reorderRoles(x, from, to), ref);
  else if (ref.kind === "type") changeSystem((x) => reorderTypeScale(x, from, to), ref);
  void s;
}

/** Moves the selected item one place earlier (-1) or later (+1) in its list. */
export function nudge(ref: ItemRef, by: -1 | 1): void {
  const doc = currentDoc();
  if (!doc) return;
  const s = doc.system;
  const keys: Record<string, string[]> = {
    color: scaleTokens(s, "color").map((t) => t.name),
    spacing: scaleTokens(s, "spacing").map((t) => t.name),
    radius: scaleTokens(s, "radius").map((t) => t.name),
    shadow: scaleTokens(s, "shadow").map((t) => t.name),
    font: fontTokens(s).map((t) => t.name),
    icon: s.icons.map((i) => i.name),
    container: containers(s).map((c) => c.key),
    role: semanticRoles(s).map((r) => r.key),
    type: s.typeScale.map((e) => e.key),
  };
  const list = keys[ref.kind];
  if (!list) return;
  const from = list.indexOf(ref.key);
  const to = from + by;
  if (from < 0 || to < 0 || to >= list.length) return;
  reorder(ref, from, to);
}

// ------------------------------------------------------------ carried out onto a layer

/** What an item puts on a layer, and the pill the drag shows. */
function carriedValue(ref: ItemRef): { text: string; swatch: string } | null {
  const doc = currentDoc();
  if (!doc) return null;
  const s = doc.system;
  if (ref.kind === "color") {
    const c = cssColor(resolveValue(s, `var(--${ref.key})`));
    return c ? { text: `${tokenLabel(ref.key)} ${toHex(c).toUpperCase()}`, swatch: toHex(c) } : null;
  }
  if (ref.kind === "role") {
    const role = semanticRoles(s).find((r) => r.key === ref.key);
    const c = role ? cssColor(roleColor(s, role)) : null;
    return c && role ? { text: `${role.label} ${toHex(c).toUpperCase()}`, swatch: toHex(c) } : null;
  }
  if (ref.kind === "type") {
    const e = s.typeScale.find((x) => x.key === ref.key);
    return e ? { text: `${e.label} · ${entryFamily(s, e)} ${e.weight} ${e.size}`, swatch: "" } : null;
  }
  if (ref.kind === "radius" || ref.kind === "shadow") return { text: `${tokenLabel(ref.key)} · ${resolveValue(s, `var(--${ref.key})`)}`, swatch: "" };
  return null;
}

/** The design system as variables in a file it is carried into: one collection, "Design
 * system", one mode; each token carried becomes (or updates) its variable. Applying the
 * same collection again replaces it as it is. */
const COLLECTION = "C:publr-design-system";
const MODE = "m:publr-default";
const variableId = (ref: ItemRef) => `V:publr-${ref.kind}-${ref.key}`;

function systemVariable(id: string, name: string, type: "color" | "number", value: unknown): Record<string, unknown>[] {
  return [
    { op: "collection", id: COLLECTION, collection: { name: "Design system", modes: [{ id: MODE, name: "Default" }] } },
    { op: "variable", id, variable: { name, collection: COLLECTION, type, values: { [MODE]: value }, description: "From the project's design system" } },
  ];
}

/** The pill under the pointer while an item is carried out (null: none). */
export function carryOut(ref: ItemRef | null, e: PointerEvent | null): void {
  const v = ref ? carriedValue(ref) : null;
  if (!ref || !e) {
    sys.ghost = { ...sys.ghost, show: false };
    return;
  }
  const target = v ? freeTarget(e) : "";
  sys.ghost = { show: true, x: e.clientX, y: e.clientY, text: v ? (target ? `Apply ${v.text}` : v.text) : "This item does not go onto a layer", swatch: v?.swatch ?? "", ok: !!v && !!target };
}

/** The layer of the canvas beside under a client point ("" none). */
function freeTarget(e: { clientX: number; clientY: number }): string {
  const s = viewerStage();
  if (!s?.doc) return "";
  const r = s.canvas.getBoundingClientRect();
  if (e.clientX < r.left || e.clientX > r.right || e.clientY < r.top || e.clientY > r.bottom) return "";
  const x = s.cam.x + (e.clientX - r.left) / s.cam.z;
  const y = s.cam.y + (e.clientY - r.top) / s.cam.z;
  return targetAt(x, y, true);
}

/** An item let go over the canvas beside: its value goes onto the layer there (bound to
 * the token once Pubd variables carry the system; for now the value). */
export function carryOver(ref: ItemRef, e: PointerEvent): void {
  sys.ghost = { ...sys.ghost, show: false };
  dsCanvas()?.clearDrop();
  const doc = currentDoc();
  const ed = viewerEditing();
  const id = freeTarget(e);
  if (!doc || !ed?.engine || !id) return;
  const s = doc.system;
  const info = ed.node(id);
  const node = info.node as Record<string, unknown>;
  let props: Record<string, unknown> | null = null;
  /** The variable the value is bound to (Pubd draft 2), added to the file beside first. */
  let bound: Record<string, unknown>[] = [];
  if (ref.kind === "color" || ref.kind === "role") {
    const v = carriedValue(ref);
    if (v?.swatch) {
      const vid = variableId(ref);
      bound = systemVariable(vid, ref.kind === "role" ? `role/${ref.key}` : `palette/${ref.key.replace(/^color-palette-/, "")}`, "color", v.swatch);
      props = { fills: [{ type: "solid", color: v.swatch, var: vid }] };
    }
  } else if (ref.kind === "type" && node.type === "text") {
    const entry = s.typeScale.find((x) => x.key === ref.key);
    if (entry) {
      const size = cssLengthPx(scaleValue(s, entry.size, "text-")) ?? 16;
      const lh = cssLengthPx(scaleValue(s, entry.lineHeight, "leading-"));
      const family = entryFamily(s, entry);
      const faces = sys.faces[family] ?? [];
      const face = faces.find((f) => f[0] === entry.weight)?.[1] ?? "Regular";
      const tcase = entry.textTransform === "uppercase" ? "upper" : entry.textTransform === "lowercase" ? "lower" : entry.textTransform === "capitalize" ? "title" : "none";
      props = { style: { ...((node.style as Record<string, unknown>) ?? {}), family, weight: entry.weight, fontStyle: face, size, lineHeight: lh === null ? "auto" : { px: lh }, letterSpacing: cssLengthPx(scaleValue(s, entry.letterSpacing, "tracking-")) ?? 0, case: tcase }, runs: [] };
    }
  } else if (ref.kind === "radius") {
    const v = cssLengthPx(resolveValue(s, `var(--${ref.key})`));
    if (v !== null) {
      const vid = variableId(ref);
      bound = systemVariable(vid, `radius/${ref.key.replace(/^radius-/, "")}`, "number", v);
      props = { radius: v, vars: { ...((node.vars as Record<string, unknown>) ?? {}), radius: vid } };
    }
  } else if (ref.kind === "shadow") {
    props = { effects: shadowEffects(resolveValue(s, `var(--${ref.key})`)) };
  }
  if (!props) return;
  try {
    try {
      ed.edit([...bound, { op: "set", node: id, props }]);
    } catch (err) {
      // An engine without variables: the value alone.
      console.warn("design system: bound as a value", err);
      const { var: _v, ...paint } = ((props.fills as Record<string, unknown>[] | undefined)?.[0] ?? {}) as Record<string, unknown>;
      const plain = { ...props };
      if (props.fills) plain.fills = [paint];
      delete plain.vars;
      ed.edit({ op: "set", node: id, props: plain });
    }
    selectFree([id]);
    sys.focus = "free";
  } catch (err) {
    console.error("design system: could not apply", err);
  }
}

export { fontRoles };
