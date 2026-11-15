// The keyboard: 1-4 modes, f fit, space pauses flicker or plays the build-up, up/down
// walk the exports, left/right step the build-up (shift: ten at a time).
import { nudge, togglePlay } from "./buildup";
import { selectNext, setMode } from "./data";
import { MODES, state } from "./store";
import { fit, toggleFlickerPause } from "./view";

export function keydown(event: KeyboardEvent): void {
  const target = event.target as HTMLElement | null;
  if (target?.tagName === "INPUT" && event.key !== " " && !event.key.startsWith("Arrow")) return;
  if (event.metaKey || event.ctrlKey || event.altKey) return;
  const mode = MODES.find((m) => m.shortcut === event.key);
  if (mode) {
    setMode(mode.key);
    return;
  }
  if (event.key === "f") {
    fit();
    return;
  }
  if (event.key === " ") {
    event.preventDefault();
    if (state.mode === "flicker") toggleFlickerPause();
    else if (state.mode === "build") togglePlay();
    return;
  }
  if (event.key === "ArrowDown" || event.key === "ArrowUp") {
    event.preventDefault();
    selectNext(event.key === "ArrowDown" ? 1 : -1);
    return;
  }
  if (state.mode === "build" && (event.key === "ArrowLeft" || event.key === "ArrowRight")) {
    event.preventDefault();
    nudge((event.key === "ArrowRight" ? 1 : -1) * (event.shiftKey ? 10 : 1));
  }
}
