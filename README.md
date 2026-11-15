# PublrDesign

A design tool for Publr, built from scratch. Three parts:

- `engine/`: PublrEngine, the rendering engine (Zig, WASM and native).
- `pubd/`: Pubd, the open document format (`.pubd`).
- `editor/`: PublrDesign, the editor application (PublrJS).

Test files and fonts (`engine/corpus/`) are not in the repository; tests that read them
need a local copy.
