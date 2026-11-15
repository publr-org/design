// Feature requests: what PublrDesign does not have yet. Every greyed item of a feature
// not built opens the Feature requests window on it (FeatureRequests.ptsx): its votes, an
// Upvote, an email to hear when it ships, and every other missing feature below.
//
// The votes and the emails live on publr.app (its `feature_requests` plugin, public
// operations at <base>/_actions/app.feature_requests.<verb>). A call carries no cookies: the
// visitor is a random id kept in this browser and sent as `Publr-Visitor`, one vote a
// feature for each. The features themselves are the parity checklist's (features.ts):
// without publr.app the window still shows them, with voting off.

import { Publr } from "publr-jsx";
import { FEATURES } from "./features";
import type { Feature } from "./features";

/** Where publr.app's feature requests answer. `?requests=<address>` on the editor's own
 * address points elsewhere (a local publr.app), remembered in this browser. */
const DEFAULT_BASE = "https://publr.app/features";
const PAGE = 200;

export type Request = Feature & { status: string; votes: number; voted: boolean };

export const requests = Publr.reactive({
  open: false,
  /** The feature the window opened on ("" the list alone). */
  focus: "",
  /** Every feature, with its votes once publr.app answered. */
  list: [] as Request[],
  /** The focused feature, and the other missing ones as the list below shows them. */
  current: null as Request | null,
  shown: [] as Request[],
  /** publr.app answered (votes and status are real). */
  live: false,
  loading: false,
  /** Why publr.app could not be reached ("" it could). */
  problem: "",
  query: "",
  sort: "votes" as "votes" | "area",
  email: "",
  /** The focused feature's email kept ("" not yet). */
  subscribed: "",
  /** The email field shown (Notify me when it ships was chosen). */
  notifying: false,
  /** The window's place. */
  x: 0,
  y: 0,
});

function base(): string {
  try {
    const asked = new URLSearchParams(location.search).get("requests");
    if (asked) localStorage.setItem("pd-requests", asked);
    return (asked ?? localStorage.getItem("pd-requests") ?? DEFAULT_BASE).replace(/\/$/, "");
  } catch {
    return DEFAULT_BASE;
  }
}

/** This browser's visitor: 24 hex characters, made once. */
function visitor(): string {
  try {
    const kept = localStorage.getItem("pd-visitor");
    if (kept && /^[0-9a-f]{24}$/.test(kept)) return kept;
    const bytes = crypto.getRandomValues(new Uint8Array(12));
    const made = Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
    localStorage.setItem("pd-visitor", made);
    return made;
  } catch {
    return "";
  }
}

async function call<T>(verb: string, input: Record<string, unknown>): Promise<T> {
  const response = await fetch(`${base()}/_actions/app.feature_requests.${verb}`, {
    method: "POST",
    headers: { "Content-Type": "application/json", "Publr-Request": "1", "Publr-Visitor": visitor() },
    body: JSON.stringify(input),
  });
  const body = (await response.json().catch(() => ({}))) as T & { error?: string };
  if (!response.ok) throw new Error(body.error ?? `HTTP ${response.status}`);
  return body;
}

const offline = (): Request[] => FEATURES.map((f) => ({ ...f, status: "Not built", votes: 0, voted: false }));

/** Reads every feature's votes and status from publr.app, page by page; the checklist's
 * own list stands in when it cannot be reached. */
async function load(): Promise<void> {
  if (requests.loading) return;
  requests.loading = true;
  if (!requests.list.length) requests.list = offline();
  refresh();
  try {
    const got: Request[] = [];
    for (let offset = 0; ; offset += PAGE) {
      const page = await call<{ features: Request[] }>("list", { offset, limit: PAGE });
      got.push(...page.features);
      if (page.features.length < PAGE) break;
    }
    // The checklist's wording and areas; publr.app's votes and status.
    const byKey = new Map(got.map((r) => [r.key, r]));
    requests.list = FEATURES.map((f) => {
      const r = byKey.get(f.key);
      return { ...f, status: r?.status ?? "Not built", votes: r?.votes ?? 0, voted: r?.voted ?? false };
    });
    requests.live = true;
    requests.problem = "";
  } catch (err) {
    console.warn("feature requests", err);
    requests.live = false;
    requests.problem = Publr.t("Could not reach publr.app: votes are off for now.");
  } finally {
    requests.loading = false;
    refresh();
  }
}

/** Opens the window on feature `key` (or on the list alone). */
export function openRequest(key = ""): void {
  requests.focus = key;
  requests.subscribed = "";
  requests.notifying = false;
  if (!requests.open) {
    requests.x = Math.max(16, Math.round(window.innerWidth / 2 - 240));
    requests.y = Math.max(16, Math.round(window.innerHeight / 2 - 300));
  }
  requests.open = true;
  refresh();
  void load();
}

export function closeRequests(): void {
  requests.open = false;
}

export const featureOf = (key: string): Request | undefined => requests.list.find((r) => r.key === key);

/** Replaces feature `key`'s votes in the list (a new row, so the window redraws it). */
function setVotes(key: string, votes: number, voted: boolean): void {
  requests.list = requests.list.map((r) => (r.key === key ? { ...r, votes, voted } : r));
  refresh();
}

/** Gives or takes back this browser's vote for `key`. */
export async function vote(key: string): Promise<void> {
  const r = featureOf(key);
  if (!r || !requests.live) return;
  const on = !r.voted;
  // At once on screen; publr.app's answer then says what it counted.
  setVotes(key, r.votes + (on ? 1 : -1), on);
  try {
    const got = await call<{ votes: number; voted: boolean }>("vote", { feature: key, on });
    setVotes(key, got.votes, got.voted);
  } catch (err) {
    console.warn("vote", err);
    setVotes(key, r.votes, r.voted);
    requests.problem = Publr.t("The vote did not reach publr.app. Try again in a moment.");
  }
}

/** Keeps `email` to hear when feature `key` changes status. */
export async function subscribe(key: string): Promise<void> {
  const email = requests.email.trim();
  if (!/^[^\s@<>,;]+@[^\s@<>,;]+\.[^\s@<>,;]+$/.test(email)) {
    requests.problem = Publr.t("That does not look like an email address.");
    return;
  }
  try {
    await call("subscribe", { feature: key, email });
    requests.subscribed = email;
    requests.problem = "";
  } catch (err) {
    console.warn("subscribe", err);
    requests.problem = Publr.t("Could not reach publr.app. Try again in a moment.");
  }
}

/** The focused feature and the other missing ones (not built, matching the search, most
 * votes or by area first), kept for the window to show. */
function refresh(): void {
  const q = requests.query.trim().toLowerCase();
  const list = requests.list.filter((r) => r.key !== requests.focus && r.status !== "Built" && (!q || `${r.title} ${r.area} ${r.description}`.toLowerCase().includes(q)));
  requests.shown = requests.sort === "votes" ? list.sort((a, b) => b.votes - a.votes || a.title.localeCompare(b.title)) : list.sort((a, b) => a.area.localeCompare(b.area) || a.title.localeCompare(b.title));
  requests.current = requests.list.find((r) => r.key === requests.focus) ?? null;
}

export function setQuery(q: string): void {
  requests.query = q;
  refresh();
}

export function setSort(sort: "votes" | "area"): void {
  requests.sort = sort;
  refresh();
}

export function windowDrag(event: PointerEvent): void {
  if (event.button !== 0 || (event.target as HTMLElement).closest("button, input")) return;
  event.preventDefault();
  const x0 = event.clientX - requests.x;
  const y0 = event.clientY - requests.y;
  const move = (e: PointerEvent) => {
    requests.x = Math.max(0, Math.min(window.innerWidth - 120, e.clientX - x0));
    requests.y = Math.max(0, Math.min(window.innerHeight - 48, e.clientY - y0));
  };
  const up = () => {
    window.removeEventListener("pointermove", move, true);
    window.removeEventListener("pointerup", up, true);
  };
  window.addEventListener("pointermove", move, true);
  window.addEventListener("pointerup", up, true);
}
