// The breakpoints the switcher offers, narrowest first, at the width each previews at:
// the block editor's own (editor/shell/Shell.ptsx, `DEVICES`: the base, md and lg
// breakpoints of editor/design/model/breakpoints.ts on the devices they preview on), and
// the Hearth theme's `breakpoint-xl` (1280, "Large desktop" as the block editor names
// `xl`), a second breakpoint on the desktop. A device may hold several breakpoints, as the
// block editor's design system groups them.
export type DeviceKey = "mobile" | "tablet" | "desktop" | "xl";
export type DeviceGroup = "mobile" | "tablet" | "desktop";
export type Device = {
  key: DeviceKey | "free";
  /** The breakpoint's name, as buttons and "editing …" say it. */
  label: string;
  /** The device it previews on, and that device's name. */
  device: DeviceGroup | "free";
  deviceLabel: string;
  icon: string;
  width: number;
  /** The theme's name for it (Base for the mobile one). */
  breakpoint: string;
  range: string;
  /** Its theme token. */
  token: string;
};

export const DEVICES: readonly Device[] = [
  { key: "mobile", label: "Mobile", device: "mobile", deviceLabel: "Mobile", icon: "device-mobile", width: 390, breakpoint: "Base", range: "< 768px", token: "publr-preview-base" },
  { key: "tablet", label: "Tablet", device: "tablet", deviceLabel: "Tablet", icon: "device-tablet", width: 768, breakpoint: "Tablet", range: "≥ 768px", token: "breakpoint-md" },
  { key: "desktop", label: "Desktop", device: "desktop", deviceLabel: "Desktop", icon: "device-desktop", width: 1024, breakpoint: "Desktop", range: "≥ 1024px", token: "breakpoint-lg" },
  { key: "xl", label: "Large desktop", device: "desktop", deviceLabel: "Desktop", icon: "device-desktop", width: 1280, breakpoint: "Large desktop", range: "≥ 1280px", token: "breakpoint-xl" },
];

export const deviceOf = (key: string) => DEVICES.find((d) => d.key === key) ?? DEVICES[2];

/** The frame's name: its device, then the breakpoint when the device has several, and
 * the range ("Mobile · Base < 768px", "Desktop · Large desktop ≥ 1280px"). */
export function frameName(d: Device): string {
  const name = d.breakpoint === d.deviceLabel ? "" : `${d.breakpoint} `;
  return `${d.deviceLabel} · ${name}${d.range}`;
}

/** The breakpoint a width falls in (mobile first: each holds from its width up). */
export function breakpointAt(width: number): Device {
  let at = DEVICES[0];
  for (const d of DEVICES) if (d === DEVICES[0] || width >= d.width) at = d;
  return at;
}

/** Free responsive mode's frame: any width, labelled by the breakpoint it falls in. */
export const freeDevice = (width: number): Device => ({ key: "free", label: "Responsive", device: "free", deviceLabel: "Responsive", icon: "responsive", width, breakpoint: "", range: "", token: "" });

/** Free widths stay between a small phone and a wide screen. */
export const FREE_MIN = 240;
export const FREE_MAX = 2560;

/** The devices the switcher shows, in order, each with its breakpoints. */
export const GROUPS: readonly { device: DeviceGroup; label: string; icon: string; breakpoints: readonly Device[] }[] = (["mobile", "tablet", "desktop"] as const).map((device) => {
  const breakpoints = DEVICES.filter((d) => d.device === device);
  return { device, label: breakpoints[0].deviceLabel, icon: breakpoints[0].icon, breakpoints };
});
