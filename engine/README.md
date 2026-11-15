# PublrEngine

The PublrDesign rendering engine: Zig, built for WASM and native.

```
zig build test                       # unit tests
zig build -Doptimize=ReleaseFast     # zig-out/bin/pe

pe import-figma corpus/landing/file.json corpus/landing/images corpus/landing/landing.pubd
pe import-fig file.fig out.pubd          # page by page, streamed: any size (zip64)
pe render corpus/landing/landing.pubd 27:51 2 out/about.png
pe score corpus/landing/landing.pubd corpus/landing/renders out/landing
pe decode image.jpg out.png
pe layout-check corpus/features/features-fig.pubd --instances --incremental 300
pe tilecheck corpus/landing/landing.pubd 47:348 0.25 1 2 16@0.68,0.3
pe gpuscene corpus/features/features-fig.pubd 1
pe gpubench big.pubd 1622-261460      # one page only: what it holds, records and frame build times

zig build wasm                       # zig-out/web/publr_engine.wasm (src/wasm.zig)
scripts/view.sh [doc.pubd | file.fig] [port]   # the browser viewer on http://127.0.0.1:8402/
```

`view.sh` builds `pe`, the WASM engine and the UI (`../editor`, `zig build` there writes
`zig-out/site`), then runs `pe view`, which serves the UI, the engine, the document and
the fonts. The viewer renders 256 px tiles per power-of-two zoom level in Web Workers
(`../editor/viewer/`); `src/session.zig` is the host-independent side of it (bytes in,
tiles and hit tests out). A tile equals the same area of a whole render at that scale;
`tilecheck` proves it for a node (whole, or a 2048 px window when large).

`score` renders every reference in the renders folder (`<node>@<scale>.png`, Figma's own
exports) and prints how many pixels match within 2/255, with and without text areas;
`out/landing/*.ours.png` and `*.diff.png` show where they differ. An export Figma framed
larger than the node's box (shadows, strokes, children past it, a text by its ink) is
compared over the area the node paints (`render.exportBounds`), the best-fitting window
of it. `pe decode <image> <out.png>` writes an image as the engine decodes it.

Corpora: `corpus/landing`, `corpus/features` and `corpus/caraway` (the 672 MB
"2024 Caraway Month" `.fig`, imported to `caraway.pubd`, with Figma's renders of every
top-level node of its first six pages in `renders/`, `depth2.json` the REST outline).

`layout-check` lays the document out again from the rules alone (every size and position
that a rule decides is first set to NaN) and compares each node with Figma's stored
result, grouped by rule (`docs/layout.md`).

Layout:

- `src/pubd/`: the Pubd model, reader and writer (`../pubd/SPEC.md`), and variables
  (`vars.zig`: what a variable is worth at a node, bound fields set to it).
- `src/import/figma.zig`: Figma REST JSON to Pubd.
- `src/import/fig/`: Figma's `.fig` file to Pubd (Kiwi reader, blobs, zip; `docs/fig-format.md`);
  `stream.zig` imports page by page with images one at a time, so a file of any size fits.
- `scripts/pubd-diff.py`: two Pubd documents compared node by node.
- `src/edit/`: the editing core: changes (`change.zig`), a node's properties by Pubd key
  (`props.zig`), and the editor (`editor.zig`): steps, undo and redo, instances following
  their main components, the relayout and invalidation an edit needs, saving
  (`.agents/specs/publr-design-editing.md`).
- `src/layout/`: layout from rules: auto layout, grids, hug / fill, text resizing,
  groups, constraints (`docs/layout.md`).
- `src/raster/`: paths, coverage masks, strokes, pixmaps, shaders, blur.
- `src/render/`: the CPU reference renderer.
- `src/gpu/`: the GPU canvas: records kept on the GPU (`records.zig`, the default) and the scene as flat primitive lists (`scene.zig`), and the WGSL
  that draws them (`docs/gpu.md`). The viewer draws with it when the browser has WebGPU
  (`?gpu=0` keeps the CPU tiles); `window.viewer.gpuReport()` checks it against the CPU
  (`gpuDiff` shows where it differs, `shadowCheck` formula shadows against passes) and
  `pe gpuscene` counts what each frame holds and benches panning and zooming at fit.
- `src/codec/`: PNG and JPEG.
- `corpus/`: test files with Figma's renders. Not part of the repo.
