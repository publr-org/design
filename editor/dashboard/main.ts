// The accuracy dashboard's page: the design system's classes compiled in the browser, the
// dashboard mounted over the whole window, the keys and resizes wired, then the first
// poll of the server's state.
import { mount } from "publr/dom";
import { component } from "publr-jsx";
import { startEngine } from "../../../ui/gallery/app/runtime/engine";
import { Dashboard } from "./Dashboard.ptsx";
import { poll, restoreMode } from "./data";
import { keydown } from "./keys";
import { applyView, fit, isFitted } from "./view";

await startEngine(new URL("../../../runtime/jit_engine.wasm", import.meta.url).href);

restoreMode();
const app = document.getElementById("app")!;
app.className = "h-screen";
mount(app, () => component(Dashboard, {}), {});

addEventListener("keydown", keydown);
addEventListener("resize", () => (isFitted() ? fit() : applyView()));
void poll();
