// The page: the design system's classes compiled in the browser, then the app (file
// browser and viewer) mounted over the whole window.
import { mount } from "publr/dom";
import { component } from "publr-jsx";
import { startEngine } from "../../../ui/gallery/app/runtime/engine";
import { configureShell } from "../design/store";
import { configure, prestart } from "../viewer/loader";
import { App } from "./App.ptsx";
import { startRouting } from "./route";

const params = new URLSearchParams(location.search);

configure(new URL("../../../publr_engine.wasm", import.meta.url).href);
configureShell(new URL("../../../publr_engine.wasm", import.meta.url).href);
// A file's or a design system's address: what opening it needs starts now, while the
// page's own classes compile and the app mounts (the engine's module, the fonts, the
// render workers, an engine on this thread).
if (location.pathname.startsWith("/file/") || location.pathname.startsWith("/system/") || params.get("system") !== null) {
  const cores = navigator.hardwareConcurrency || 4;
  prestart(Number(params.get("workers")) || Math.min(3, Math.max(1, cores - 1)));
}

await startEngine(new URL("../../../runtime/jit_engine.wasm", import.meta.url).href);

// `/?system` (`/?system=untitled-ui` for that demo): the project Bring in seeded, on its
// design system tab. An earlier address, `/file/<id>?system=<project>`, opens that
// project's design system with the file as its reference.
const systemParam = params.get("system");
if (systemParam !== null) {
  const old = /^\/file\/([^/]+)\/?$/.exec(location.pathname);
  const to = /^[0-9a-f]{16}$/.test(systemParam) ? `/system/${systemParam}${old ? `?ref=${old[1]}` : ""}` : await (await import("../system/store")).seededAddress(systemParam);
  history.replaceState(null, "", to);
  const { navigate } = await import("./route");
  navigate(location.pathname + location.search);
}

const app = document.getElementById("app")!;
app.className = "h-screen";
mount(
  app,
  () =>
    component(App, {
      workers: Number(params.get("workers")) || undefined,
      cacheMiB: Number(params.get("cache")) || undefined,
      gpu: params.has("gpu") ? params.get("gpu") !== "0" : undefined,
      hud: params.has("hud"),
    }),
  {},
);
startRouting();
