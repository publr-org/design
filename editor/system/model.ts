// The design system the canvas shows and edits: the builder's own `DesignSystem`
// (../../../editor/design/model, read-only), with the builder's operations, and the few
// edits the builder makes in its pages that its model leaves to them (reordering,
// renaming a palette colour). Every edit here returns a new document; nothing is kept.
//
// What the canvas adds beside the builder's shape: the primitive blocks' defaults as
// the components they were taken from (`primitives`), until a component is lowered to
// a block's starting document.

import { Publr } from "publr-jsx";
import { addBreakpoint, breakpointDevice, moveBreakpoint, removeBreakpoint, setBreakpointWidth, styleBreakpoints } from "../../../editor/design/model/breakpoints";
import type { Breakpoint, Device } from "../../../editor/design/model/breakpoints";
import { addContainer, containers, removeContainer, renameContainer, setContainerProp, setContainerWidth } from "../../../editor/design/model/containers";
import type { Container } from "../../../editor/design/model/containers";
import { familyLabel, fontTokenName, putFont, removeFont, retargetReferences, setFontRole } from "../../../editor/design/model/fonts";
import { removeIcon } from "../../../editor/design/model/icons";
import { addRole, removeRole, updateRole } from "../../../editor/design/model/roles";
import { colorContexts, completeSystem, fontFamilyTokens, fontRoles, paletteTokens, resolveValue, roleToken, semanticRoles, setToken, titleCase, tokenValue } from "../../../editor/design/model/system";
import type { ColorRole, DesignSystem, FontDefinition, IconDefinition, Token, TypeScaleEntry } from "../../../editor/design/model/system";
import type { FontRole } from "../../../editor/design/model/system";
import { addStyle, removeStyle, styleKey, updateStyle } from "../../../editor/design/model/typescale";

export type { Breakpoint, ColorRole, Container, Device, DesignSystem, FontDefinition, FontRole, IconDefinition, Token, TypeScaleEntry };

/** A primitive block's default taken from a component: its name and its Pubd node. */
export type Primitive = { name: string; node: Record<string, unknown> };

/** What the canvas keeps: the builder's document and the primitives' components. */
export type Doc = { system: DesignSystem; primitives: Record<string, Primitive> };

/** The builder's sections, in its order. */
export type SectionKey = "tokens" | "fonts" | "icons" | "containers" | "semantic" | "typography" | "typescale" | "blocks" | "breakpoints" | "patterns" | "templates";

export type ItemKind = "color" | "spacing" | "radius" | "shadow" | "font" | "icon" | "container" | "role" | "fontRole" | "type" | "block" | "breakpoint";

/** One item of a section. */
export type ItemRef = { kind: ItemKind; key: string };

export const SECTION_OF: Record<ItemKind, SectionKey> = {
  color: "tokens",
  spacing: "tokens",
  radius: "tokens",
  shadow: "tokens",
  font: "fonts",
  icon: "icons",
  container: "containers",
  role: "semantic",
  fontRole: "typography",
  type: "typescale",
  block: "blocks",
  breakpoint: "breakpoints",
};

/** The groups and sections of the left panel and the canvas, as the builder orders them. */
export const GROUPS: { key: string; label: string; sections: { key: SectionKey; label: string; icon: string; note: string }[] }[] = [
  {
    key: "library",
    label: Publr.t("Library"),
    sections: [
      { key: "tokens", label: Publr.t("Token library"), icon: "token-library", note: Publr.t("The raw values everything else points at: the palette, spacing, radii and shadows.") },
      { key: "fonts", label: Publr.t("Fonts"), icon: "fonts-icons", note: Publr.t("The families the site loads, behind the font tokens.") },
      { key: "icons", label: Publr.t("Icons"), icon: "icon", note: Publr.t("The approved icons the Icon block may use.") },
      { key: "containers", label: Publr.t("Container sizes"), icon: "container-sizes", note: Publr.t("Named page widths blocks refer to, with their gutters.") },
    ],
  },
  {
    key: "semantic",
    label: Publr.t("Semantic layer"),
    sections: [
      { key: "semantic", label: Publr.t("Semantic colors"), icon: "semantic-colors", note: Publr.t("The jobs colours do, each pointing at a palette colour.") },
      { key: "typography", label: Publr.t("Typography"), icon: "element-typography", note: Publr.t("The font roles, each pointing at a family.") },
      { key: "typescale", label: Publr.t("Type scale"), icon: "scale-bars", note: Publr.t("Named text styles riding the font roles.") },
    ],
  },
  {
    key: "defaults",
    label: Publr.t("Defaults"),
    sections: [{ key: "blocks", label: Publr.t("Primitive blocks"), icon: "primitive-blocks", note: Publr.t("The starting recipe of each content block.") }],
  },
  {
    key: "system",
    label: Publr.t("System"),
    sections: [
      { key: "breakpoints", label: Publr.t("Breakpoints"), icon: "responsive", note: Publr.t("Where the layout changes, mobile first, each under its device.") },
      { key: "patterns", label: Publr.t("Patterns"), icon: "pattern-library", note: Publr.t("The project's reusable compositions; each opens in its own editor.") },
      { key: "templates", label: Publr.t("Templates"), icon: "layout-rows", note: Publr.t("The structure of each content type; each opens in its own editor.") },
    ],
  },
];

export const sectionLabel = (key: SectionKey) => GROUPS.flatMap((g) => g.sections).find((s) => s.key === key)?.label ?? key;

/** The scale prefix of a token kind. */
export const TOKEN_PREFIX: Record<"color" | "spacing" | "radius" | "shadow", string> = {
  color: "color-palette-",
  spacing: "spacing-",
  radius: "radius-",
  shadow: "shadow-",
};

// ------------------------------------------------------------ reading

/** The tokens of a scale kind, in the document's order. */
export function scaleTokens(system: DesignSystem, kind: "color" | "spacing" | "radius" | "shadow"): Token[] {
  if (kind === "color") return paletteTokens(system);
  const prefix = TOKEN_PREFIX[kind];
  return system.tokens.filter((t) => t.name.startsWith(prefix) && !t.name.includes("--"));
}

/** A token's label: its key in title case ("color-palette-sky-blue" → "Sky Blue"). */
export function tokenLabel(name: string): string {
  for (const prefix of Object.values(TOKEN_PREFIX)) if (name.startsWith(prefix)) return titleCase(name.slice(prefix.length));
  return titleCase(name);
}

export const fonts = (system: DesignSystem) => fontFamilyTokens(system);
export const fontLabel = (system: DesignSystem, token: Token) => familyLabel(system, token);
export { breakpointDevice, colorContexts, containers, fontRoles, resolveValue, roleToken, semanticRoles, styleBreakpoints, tokenValue };

/** The family a font role (or family token) resolves to ("" when none). */
export function familyOf(system: DesignSystem, token: string): string {
  const target = fontRoles(system).find((r) => r.token === token)?.target ?? token;
  const t = system.tokens.find((x) => x.name === target);
  return t ? familyLabel(system, t) : "";
}

/** The family a type scale entry is set in. */
export const entryFamily = (system: DesignSystem, entry: TypeScaleEntry) => familyOf(system, `font-${entry.fontRole}`);

/** The palette token a role points at in the default context ("" for a literal). */
export function rolePalette(system: DesignSystem, role: string): string {
  const v = tokenValue(system, roleToken("default", role)) ?? "";
  return /^var\(--([a-z0-9-]+)\)$/.exec(v.trim())?.[1] ?? "";
}

/** A role's colour as a CSS value. */
export const roleColor = (system: DesignSystem, role: ColorRole) => resolveValue(system, tokenValue(system, roleToken("default", role.key)) ?? role.value);

// ------------------------------------------------------------ edits

/** The tokens named `order` put in that order, in the places they held. */
export function reorderTokens(system: DesignSystem, order: string[]): DesignSystem {
  const wanted = new Set(order);
  const places: number[] = [];
  system.tokens.forEach((t, i) => wanted.has(t.name) && places.push(i));
  const byName = new Map(system.tokens.map((t) => [t.name, t]));
  const tokens = [...system.tokens];
  places.forEach((place, k) => (tokens[place] = byName.get(order[k])!));
  return { ...system, tokens };
}

/** `list` with the item at `from` moved to `to` (an index in the list without it). */
export function moved<T>(list: readonly T[], from: number, to: number): T[] {
  const out = [...list];
  const [x] = out.splice(from, 1);
  out.splice(Math.max(0, Math.min(out.length, to)), 0, x);
  return out;
}

/** A token name of `prefix` not taken yet, from a label. */
export function freeTokenName(system: DesignSystem, prefix: string, label: string): string {
  const slug =
    label
      .normalize("NFD")
      .replace(/[̀-ͯ]/g, "")
      .toLowerCase()
      .replace(/[^a-z0-9]+/g, "-")
      .replace(/^-|-$/g, "") || "new";
  let name = `${prefix}${slug}`;
  for (let n = 2; system.tokens.some((t) => t.name === name); n++) name = `${prefix}${slug}-${n}`;
  return name;
}

/** Renames a token, every `var(--…)` pointing at it following. */
export function renameToken(system: DesignSystem, from: string, to: string): DesignSystem {
  if (from === to || system.tokens.some((t) => t.name === to)) return system;
  const tokens = retargetReferences(system.tokens, from, to).map((t) => (t.name === from ? { name: to, value: t.value } : t));
  return { ...system, tokens, managedColorTokens: system.managedColorTokens.map((n) => (n === from ? to : n)) };
}

/** Adds a scale token after the last of its kind. */
export function addScaleToken(system: DesignSystem, kind: "color" | "spacing" | "radius" | "shadow", label: string, value: string): { system: DesignSystem; name: string } {
  const name = freeTokenName(system, TOKEN_PREFIX[kind], label);
  const list = scaleTokens(system, kind);
  const last = list.length ? system.tokens.findIndex((t) => t.name === list[list.length - 1].name) : -1;
  const tokens = [...system.tokens];
  tokens.splice(last < 0 ? tokens.length : last + 1, 0, { name, value });
  return { system: { ...system, tokens }, name };
}

/** Removes a scale token; what pointed at it keeps its value. */
export function removeScaleToken(system: DesignSystem, name: string): DesignSystem {
  const value = resolveValue(system, `var(--${name})`);
  const tokens = system.tokens.filter((t) => t.name !== name).map((t) => (t.value.trim() === `var(--${name})` ? { ...t, value } : t));
  return { ...system, tokens, managedColorTokens: system.managedColorTokens.filter((n) => n !== name) };
}

export const setValue = (system: DesignSystem, name: string, value: string) => setToken(system, name, value);

/** A new family: `font-<slug>` with a definition the site hosts (files to be added). */
export function addFont(system: DesignSystem, family: string, fallback: FontDefinition["fallback"]): { system: DesignSystem; token: string } | string {
  let token = fontTokenName(family);
  if (!token) return Publr.t("Give the family a name.");
  for (let n = 2; system.tokens.some((t) => t.name === token); n++) token = `${fontTokenName(family)}-${n}`;
  const value = `${/[^a-z0-9-]/i.test(family) ? `"${family}"` : family}, ${fallback}`;
  const next = putFont(system, token, value, { token, family, fallback, provider: "files", faces: [] });
  return typeof next === "string" ? next : { system: next, token };
}

/** A family's definition changed in place (its family name, fallback); the token's
 * stack follows. */
export function setFontFamily(system: DesignSystem, token: string, family: string, fallback: FontDefinition["fallback"]): DesignSystem {
  const def = system.fonts.find((f) => f.token === token);
  const value = `${/[^a-z0-9-]/i.test(family) ? `"${family}"` : family}, ${fallback}`;
  const next = putFont(system, token, value, def ? { ...def, family, fallback } : { token, family, fallback, provider: "system", weights: [400, 700], italic: false });
  return typeof next === "string" ? system : next;
}

export function dropFont(system: DesignSystem, token: string): DesignSystem {
  const other = fontFamilyTokens(system).find((t) => t.name !== token);
  return other ? removeFont(system, token, other.name) : system;
}

export { addBreakpoint, addContainer, addRole, addStyle, moveBreakpoint, removeBreakpoint, removeContainer, removeIcon, removeRole, removeStyle, renameContainer, setBreakpointWidth, setContainerProp, setContainerWidth, setFontRole, styleKey, updateRole, updateStyle };

/** A new type scale entry named `label` (made unique), with `patch` over the builder's
 * starting values. */
export function addEntry(system: DesignSystem, label: string, patch: Partial<TypeScaleEntry>): { system: DesignSystem; key: string } {
  let name = label.trim() || "Style";
  for (let n = 2; system.typeScale.some((e) => e.key === styleKey(name)); n++) name = `${label.trim() || "Style"} ${n}`;
  const next = addStyle(system, name);
  if (typeof next === "string") return { system, key: "" };
  const key = styleKey(name);
  return { system: updateStyle(next, key, patch), key };
}

/** Points a role at a palette colour (or sets a literal colour). */
export function setRoleColor(system: DesignSystem, role: string, value: string, context = "default"): DesignSystem {
  return setToken(system, roleToken(context, role), value);
}

/** The palette token a role points at in `context` ("" for a literal or none). */
export function rolePaletteIn(system: DesignSystem, role: string, context: string): string {
  const v = tokenValue(system, roleToken(context, role)) ?? "";
  return /^var\(--([a-z0-9-]+)\)$/.exec(v.trim())?.[1] ?? "";
}

/** A semantic role named `label`, pointing at the first palette colour. */
export function newRole(system: DesignSystem, label: string): { system: DesignSystem; key: string } {
  let name = label;
  for (let n = 2; semanticRoles(system).some((r) => r.key === styleKey(name)); n++) name = `${label} ${n}`;
  const r = addRole(system, name, "");
  return r.system ? { system: r.system, key: styleKey(name) } : { system, key: "" };
}

/** Reorders the semantic roles (the role list; their tokens stay where they are). */
export const reorderRoles = (system: DesignSystem, from: number, to: number): DesignSystem => ({ ...system, roles: moved(semanticRoles(system), from, to) });

export const reorderTypeScale = (system: DesignSystem, from: number, to: number): DesignSystem => ({ ...system, typeScale: moved(system.typeScale, from, to) });

export const reorderIcons = (system: DesignSystem, from: number, to: number): DesignSystem => ({ ...system, icons: moved(system.icons, from, to) });

/** The container list token in a new order. */
export function reorderContainers(system: DesignSystem, from: number, to: number): DesignSystem {
  const keys = moved(
    containers(system).map((c) => c.key),
    from,
    to,
  );
  return setToken(system, "publr-containers", keys.join(" "));
}

/** A complete document from what a store or a seed held. */
export function completeDoc(d: Partial<Doc> & { system?: Partial<DesignSystem> }): Doc {
  return { system: completeSystem(d.system ?? {}), primitives: { ...(d.primitives ?? {}) } };
}
