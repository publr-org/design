//! PublrDesign's UI build: `design_gen <design_editor_dir> <ui_dir> <icons_dir> <runtime_dir> <jit_wasm> <preflight_css> <out_dir>`.
//!
//! Lowers every `.ptsx` and `.ts` under the UI's source directories, the design system's
//! `src`, the gallery's class runtime (the jit wrapper and theme) and the icon set
//! through pjsx's DOM target into ES modules, keeping the workspace's directory shape
//! (`publr-design/editor/<dir>`, `ui/...`, `icons/...`) so the relative imports keep
//! resolving. Copies the PublrJS runtime and the jit engine beside them and writes the
//! pages, whose import map resolves the bare `publr` specifiers.
//!
//! Run from `zig build`; no node anywhere.
const std = @import("std");
const publr_icons = @import("publr_icons");
const pjsx = @import("pjsx");

const file_bytes_max = 4 << 20;
const runtime_import = "publr-jsx";

/// The UI's source directories, lowered into `publr-design/editor/<dir>`.
const source_dirs = [_][]const u8{ "app", "home", "viewer", "design", "dashboard", "content", "system" };

const Gen = struct {
    arena: std.mem.Allocator,
    io: std.Io,
    out: std.Io.Dir,
    lowered: u32 = 0,
    failures: u32 = 0,
};

pub fn main(init: std.process.Init) u8 {
    return run(init) catch |err| {
        std.debug.print("design_gen: {s}\n", .{@errorName(err)});
        return 1;
    };
}

fn usage() u8 {
    std.debug.print("usage: design_gen <design_editor_dir> <ui_dir> <icons_dir> <runtime_dir> <jit_wasm> <preflight_css> <out_dir>\n", .{});
    return 2;
}

fn run(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;
    var args = try init.minimal.args.iterateAllocator(arena);
    _ = args.next();
    const editor_dir = args.next() orelse return usage();
    const ui_dir = args.next() orelse return usage();
    const icons_dir = args.next() orelse return usage();
    const runtime_dir = args.next() orelse return usage();
    const jit_wasm = args.next() orelse return usage();
    const preflight_css = args.next() orelse return usage();
    const out_dir_path = args.next() orelse return usage();
    if (args.next() != null) return usage();

    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, out_dir_path);
    var gen: Gen = .{
        .arena = arena,
        .io = io,
        .out = try cwd.openDir(io, out_dir_path, .{}),
    };
    defer gen.out.close(io);

    for (source_dirs) |dir| try lower_tree(&gen, editor_dir, dir, try std.fmt.allocPrint(arena, "publr-design/editor/{s}", .{dir}));
    try lower_tree(&gen, ui_dir, "src", "ui/src");
    try lower_file(&gen, ui_dir, "gallery/app/runtime/theme.ts", "ui/gallery/app/runtime/theme.js");
    try lower_file(&gen, ui_dir, "gallery/app/runtime/engine.ts", "ui/gallery/app/runtime/engine.js");
    try lower_file(&gen, icons_dir, "src/index.ts", "icons/src/index.js");
    // Content mode's documents, read with the block editor's own model, blocks and demo
    // site (../../editor, lowered into `editor/...`; never changed from here).
    const block_editor = try std.fs.path.join(arena, &.{ editor_dir, "../../editor" });
    try lower_tree(&gen, block_editor, "model", "editor/model");
    try lower_tree(&gen, block_editor, "blocks", "editor/blocks");
    for ([_][]const u8{ "harness/hearth", "harness/templates", "harness/home-patterns", "harness/demo-theme", "canvas/engine" }) |stem| {
        try lower_file(&gen, block_editor, try std.fmt.allocPrint(arena, "{s}.ts", .{stem}), try std.fmt.allocPrint(arena, "editor/{s}.js", .{stem}));
    }
    // The design system canvas edits the builder's own `DesignSystem` with the builder's
    // model (read-only from ../../editor/design/model; see publr-design-flow.md, "The
    // design system canvas").
    for ([_][]const u8{ "system", "colors", "typescale", "breakpoints", "fonts", "icons", "containers", "roles", "library" }) |stem| {
        try lower_file(&gen, block_editor, try std.fmt.allocPrint(arena, "design/model/{s}.ts", .{stem}), try std.fmt.allocPrint(arena, "editor/design/model/{s}.js", .{stem}));
    }
    try write_default_theme(&gen, try std.fs.path.join(arena, &.{ editor_dir, "../../jit/src/default-theme.zon" }));
    // The runtime adapter re-exports the runtime's source tree; here the runtime is the
    // built one, reached by the import map.
    try write_out(&gen, "ui/src/publr-runtime.js", "export * from \"publr\";\n");
    if (gen.failures != 0) {
        std.debug.print("design_gen: {d} of {d} modules did not lower\n", .{ gen.failures, gen.lowered + gen.failures });
        return 1;
    }

    try copy_tree(&gen, runtime_dir, "runtime", ".js");
    try copy_file(&gen, jit_wasm, "runtime/jit_engine.wasm");
    try copy_file(&gen, preflight_css, "preflight.css");
    try copy_file(&gen, try std.fs.path.join(arena, &.{ ui_dir, "gallery/app/styles/gallery.css" }), "palette.css");
    // The editor shell's tokens (light and dark) and its UI face, Inter (OFL).
    try copy_file(&gen, try std.fs.path.join(arena, &.{ editor_dir, "design/shell.css" }), "shell.css");
    try copy_file(&gen, try std.fs.path.join(arena, &.{ editor_dir, "../engine/corpus/fonts-variable/Inter-3.19[wght,slnt].ttf" }), "shell/inter.ttf");
    // The demo site's stylesheets and the block editor's manual test fixtures.
    try copy_file(&gen, try std.fs.path.join(arena, &.{ block_editor, "harness/hearth.css" }), "editor/harness/hearth.css");
    try copy_file(&gen, try std.fs.path.join(arena, &.{ block_editor, "harness/site.css" }), "editor/harness/site.css");
    try write_fixtures(&gen, try std.fs.path.join(arena, &.{ block_editor, "tests/manual" }));
    for (pages) |page| try write_out(&gen, page.path, try page_html(&gen, page));
    return 0;
}

/// Lowers every source file under `<root>/<sub>` into `<out>/<prefix>/...`.
fn lower_tree(gen: *Gen, root: []const u8, sub: []const u8, prefix: []const u8) !void {
    const base = try std.fs.path.join(gen.arena, &.{ root, sub });
    var dir = std.Io.Dir.cwd().openDir(gen.io, base, .{
        .iterate = true,
    }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close(gen.io);
    var walker = try dir.walk(gen.arena);
    defer walker.deinit();

    while (try walker.next(gen.io)) |entry| {
        if (entry.kind != .file) continue;
        const name = entry.basename;
        const ptsx = std.mem.endsWith(u8, name, ".ptsx");
        const ts = std.mem.endsWith(u8, name, ".ts") and !std.mem.endsWith(u8, name, ".d.ts");
        if (!ptsx and !ts) continue;
        const stem = name[0 .. name.len - (if (ptsx) @as(usize, 5) else 3)];
        const rel_dir = std.fs.path.dirname(entry.path) orelse "";
        const out_path = try std.fmt.allocPrint(gen.arena, "{s}/{s}{s}{s}.js", .{
            prefix, rel_dir, if (rel_dir.len > 0) "/" else "", stem,
        });
        try lower_file(gen, base, try gen.arena.dupe(u8, entry.path), out_path);
    }
}

fn lower_file(gen: *Gen, root: []const u8, sub_path: []const u8, out_path: []const u8) !void {
    const filename = try std.fs.path.join(gen.arena, &.{ root, sub_path });
    const source = try std.Io.Dir.cwd().readFileAlloc(gen.io, filename, gen.arena, .limited(file_bytes_max));
    var resolver = pjsx.FileResolver{
        .io = gen.io,
    };
    const output = pjsx.dom.transformPjsxToDom(gen.arena, source, filename, .{
        .runtime_import = runtime_import,
        .resolver = resolver.resolver(),
    }) catch {
        std.debug.print("{s}: {s}\n", .{ filename, pjsx.lastError() });
        gen.failures += 1;
        return;
    };
    try write_out(gen, out_path, try browser_specifiers(gen.arena, output.code));
    gen.lowered += 1;
}

/// The compiler rewrites `.ptsx` imports to `.js` but passes TypeScript-style specifiers
/// through; a browser resolves none of those, so every relative specifier in the output
/// ends in `.js` exactly once.
fn browser_specifiers(arena: std.mem.Allocator, code: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    var rest = code;
    while (std.mem.indexOf(u8, rest, "\"")) |open| {
        const close = std.mem.indexOfScalarPos(u8, rest, open + 1, '"') orelse break;
        const specifier = rest[open + 1 .. close];
        const before = std.mem.trimEnd(u8, rest[0..open], " \t\n");
        const is_import = std.mem.endsWith(u8, before, "from") or std.mem.endsWith(u8, before, "import") or std.mem.endsWith(u8, before, "import(");
        try w.writeAll(rest[0 .. open + 1]);
        if (is_import and specifier.len > 0 and specifier[0] == '.') {
            var stem = specifier;
            for ([_][]const u8{ ".ptsx", ".tsx", ".ts", ".js" }) |extension| {
                if (std.mem.endsWith(u8, stem, extension)) {
                    stem = stem[0 .. stem.len - extension.len];
                    break;
                }
            }
            try w.print("{s}.js", .{stem});
        } else {
            try w.writeAll(specifier);
        }
        try w.writeAll("\"");
        rest = rest[close + 1 ..];
    }
    try w.writeAll(rest);
    return out.written();
}

fn write_out(gen: *Gen, out_path: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(out_path)) |dir| try gen.out.createDirPath(gen.io, dir);
    try gen.out.writeFile(gen.io, .{
        .sub_path = out_path,
        .data = data,
    });
}

fn copy_file(gen: *Gen, from: []const u8, out_path: []const u8) !void {
    const data = try std.Io.Dir.cwd().readFileAlloc(gen.io, from, gen.arena, .limited(64 << 20));
    try write_out(gen, out_path, data);
}

fn copy_tree(gen: *Gen, from: []const u8, out_prefix: []const u8, extension: []const u8) !void {
    var dir = try std.Io.Dir.cwd().openDir(gen.io, from, .{
        .iterate = true,
    });
    defer dir.close(gen.io);
    var walker = try dir.walk(gen.arena);
    defer walker.deinit();
    while (try walker.next(gen.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, extension)) continue;
        const source = try std.fs.path.join(gen.arena, &.{ from, entry.path });
        const out_path = try std.fs.path.join(gen.arena, &.{ out_prefix, entry.path });
        try copy_file(gen, source, try gen.arena.dupe(u8, out_path));
    }
}

/// `editor/design/model/jit-defaults.js`: the jit's default theme, the tokens the
/// builder's starter system begins from (as the block editor's own build writes it).
fn write_default_theme(gen: *Gen, from: []const u8) !void {
    const Theme = struct {
        tokens: []const struct {
            name: []const u8,
            value: []const u8,
        },
    };
    const source = try std.Io.Dir.cwd().readFileAllocOptions(gen.io, from, gen.arena, .limited(file_bytes_max), .of(u8), 0);
    const theme = try std.zon.parse.fromSliceAlloc(Theme, gen.arena, source, null, .{
        .ignore_unknown_fields = true,
    });
    var out: std.Io.Writer.Allocating = .init(gen.arena);
    try out.writer.writeAll("// Generated by design_gen from the jit's default-theme.zon.\nexport const JIT_DEFAULT_TOKENS = ");
    try std.json.Stringify.value(theme.tokens, .{}, &out.writer);
    try out.writer.writeAll(";\n");
    try write_out(gen, "editor/design/model/jit-defaults.js", out.written());
}

/// `publr-design/editor/content/generated/fixtures.js`: the block editor's manual test
/// fixtures (`tests/manual/<group>/<name>.md`: the title from the front matter, the HTML
/// under "## Fixture"), the documents Content mode opens besides the demo homepage.
fn write_fixtures(gen: *Gen, manual_dir: []const u8) !void {
    var out: std.Io.Writer.Allocating = .init(gen.arena);
    const w = &out.writer;
    try w.writeAll("// Generated by design_gen from editor/tests/manual: one entry per fixture.\nexport const fixtures = [\n");
    for ([_][]const u8{ "blocks", "features" }) |group| {
        const base = try std.fs.path.join(gen.arena, &.{ manual_dir, group });
        var dir = std.Io.Dir.cwd().openDir(gen.io, base, .{
            .iterate = true,
        }) catch continue;
        defer dir.close(gen.io);
        var names: std.ArrayList([]const u8) = .empty;
        var it = dir.iterate();
        while (try it.next(gen.io)) |entry| {
            if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".md")) try names.append(gen.arena, try gen.arena.dupe(u8, entry.name));
        }
        std.mem.sort([]const u8, names.items, {}, struct {
            fn less(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.less);
        for (names.items) |name| {
            const source = try dir.readFileAlloc(gen.io, name, gen.arena, .limited(file_bytes_max));
            const html = fixture_html(source) orelse continue;
            const title = fixture_title(source) orelse name[0 .. name.len - 3];
            const key = try std.fmt.allocPrint(gen.arena, "{s}-{s}", .{ group, name[0 .. name.len - 3] });
            try w.writeAll("  { key: ");
            try std.json.Stringify.value(key, .{}, w);
            try w.writeAll(", group: ");
            try std.json.Stringify.value(group, .{}, w);
            try w.writeAll(", title: ");
            try std.json.Stringify.value(title, .{}, w);
            try w.writeAll(", html: ");
            try std.json.Stringify.value(html, .{}, w);
            try w.writeAll(" },\n");
        }
    }
    try w.writeAll("];\n");
    try write_out(gen, "publr-design/editor/content/generated/fixtures.js", out.written());
}

fn fixture_title(source: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, source, "---\n")) return null;
    const end = std.mem.indexOfPos(u8, source, 4, "\n---") orelse return null;
    var lines = std.mem.splitScalar(u8, source[4..end], '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "title:")) return std.mem.trim(u8, line["title:".len..], " \t\"");
    }
    return null;
}

fn fixture_html(source: []const u8) ?[]const u8 {
    const heading = std.mem.indexOf(u8, source, "## Fixture") orelse return null;
    const open = std.mem.indexOfPos(u8, source, heading, "```html\n") orelse return null;
    const start = open + "```html\n".len;
    const close = std.mem.indexOfPos(u8, source, start, "\n```") orelse return null;
    return source[start..close];
}

const Page = struct {
    path: []const u8,
    title: []const u8,
    entry: []const u8,
    /// Classes on `<html>`: `dark` selects the palette's dark tokens before the first paint.
    html_class: []const u8 = "",
    /// A script in the head that runs before the first paint (the theme's classes).
    boot: []const u8 = "",
};

/// The app's first paint on a file's address (`/file/<id>`): the editor's theme, as the
/// person chose it (`pd-theme`) or the system's, and the splash's field (`pd-boot`), so
/// nothing light flashes before the splash draws. The shell takes the classes over.
const app_boot =
    \\<script>try{if(/^\/(file|content)\//.test(location.pathname)){var c=document.documentElement.classList,t=localStorage.getItem("pd-theme");c.add("pd","pd-boot");if(t?t==="dark":!window.matchMedia||matchMedia("(prefers-color-scheme: dark)").matches)c.add("pd-dark")}}catch(e){}</script>
;

/// The pages: the app (file browser and viewer) at the root; the accuracy dashboard
/// (`pe serve`) beside it. URLs are root-absolute: the app's own routes (`/file/<id>`)
/// serve the same page.
const pages = [_]Page{
    .{
        .path = "index.html",
        .title = "PublrDesign",
        .entry = "/publr-design/editor/app/main.js",
        .boot = app_boot,
    },
    .{
        .path = "dashboard.html",
        .title = "PublrEngine accuracy",
        .entry = "/publr-design/editor/dashboard/main.js",
        .html_class = "dark",
    },
};

/// A page: the head with the import map, the mount point, the entry module and the icon
/// sprite the way a server writes it.
fn page_html(gen: *Gen, page: Page) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(gen.arena);
    const w = &out.writer;
    try w.print(page_head, .{ page.html_class, page.title, page.boot });
    try w.print("<div id=\"app\"></div>\n<script type=\"module\" src=\"{s}\"></script>\n", .{page.entry});
    try w.writeAll("<svg id=\"publr-icon-sprite\" style=\"position:absolute;width:0;height:0;overflow:hidden\" aria-hidden=\"true\">");
    inline for (@typeInfo(publr_icons.Name).@"enum".fields) |field| {
        const name = comptime publr_icons.kebab(field.name);
        try w.print("<symbol id=\"publr-icon-{s}\" viewBox=\"{s}\" fill=\"none\">{s}</symbol>", .{ name, publr_icons.view_box, @field(publr_icons, field.name) });
    }
    try w.writeAll("</svg>\n</body>\n</html>\n");
    return out.written();
}

const page_head =
    \\<!doctype html>
    \\<html lang="en" class="{s}">
    \\<head>
    \\<meta charset="utf-8">
    \\<meta name="viewport" content="width=device-width, initial-scale=1">
    \\<title>{s}</title>
    \\{s}
    \\<link rel="icon" type="image/svg+xml" href="data:image/svg+xml,%3Csvg xmlns=%22http://www.w3.org/2000/svg%22 viewBox=%220 0 512 512%22 width=%22512%22 height=%22512%22 role=%22img%22 aria-label=%22Publr%22%3E%3Crect width=%22512%22 height=%22512%22 fill=%22%23161a1f%22/%3E%3Cg transform=%22translate(96 96) scale(9.4118)%22 fill=%22%23ffffff%22%3E%3Cpath d=%22M19.598 18.5C18.7696 19.9349 16.9348 20.4265 15.4999 19.5981C14.065 18.7696 13.5734 16.9349 14.4018 15.5C15.2303 14.0651 17.065 13.5735 18.4999 14.4019C19.9348 15.2303 20.4264 17.0651 19.598 18.5Z%22/%3E%3Cpath d=%22M23.232 10.2058C22.6797 11.1623 21.4565 11.4901 20.4999 10.9378C19.5433 10.3855 19.2156 9.16235 19.7679 8.20576C20.3201 7.24918 21.5433 6.92143 22.4999 7.47371C23.4565 8.026 23.7842 9.24918 23.232 10.2058Z%22/%3E%3Cpath d=%22M19.7679 25.7944C19.2156 24.8378 19.5433 23.6146 20.4999 23.0623C21.4565 22.51 22.6797 22.8378 23.232 23.7944C23.7843 24.7509 23.4565 25.9741 22.4999 26.5264C21.5433 27.0787 20.3202 26.7509 19.7679 25.7944Z%22/%3E%3Cpath d=%22M25.9999 19.0001C24.8953 19.0001 23.9999 18.1047 23.9999 17.0001C23.9999 15.8956 24.8953 15.0001 25.9999 15.0001C27.1045 15.0001 27.9999 15.8956 27.9999 17.0001C27.9999 18.1047 27.1045 19.0001 25.9999 19.0001Z%22/%3E%3Cpath d=%22M14.232 25.7942C13.6797 26.7508 12.4565 27.0786 11.4999 26.5263C10.5433 25.974 10.2156 24.7508 10.7679 23.7942C11.3201 22.8376 12.5433 22.5099 13.4999 23.0622C14.4565 23.6145 14.7842 24.8376 14.232 25.7942Z%22/%3E%3Cpath d=%22M10.7679 10.2059C10.2157 9.24936 10.5434 8.02618 11.5 7.4739C12.4566 6.92161 13.6798 7.24936 14.232 8.20595C14.7843 9.16253 14.4566 10.3857 13.5 10.938C12.5434 11.4903 11.3202 11.1625 10.7679 10.2059Z%22/%3E%3Cpath d=%22M7.99999 19.0002C6.89542 19.0002 5.99999 18.1047 5.99999 17.0002C5.99999 15.8956 6.89542 15.0002 7.99999 15.0002C9.10456 15.0002 9.99999 15.8956 9.99999 17.0002C9.99999 18.1047 9.10456 19.0002 7.99999 19.0002Z%22/%3E%3Cpath d=%22M25.8659 3.64359C25.5898 4.12188 24.9782 4.28575 24.4999 4.00961C24.0216 3.73347 23.8577 3.12188 24.1339 2.64359C24.41 2.16529 25.0216 2.00142 25.4999 2.27756C25.9782 2.5537 26.1421 3.16529 25.8659 3.64359Z%22/%3E%3Cpath d=%22M33.0001 18.0002C32.4478 18.0002 32.0001 17.5524 32.0001 17.0002C32.0001 16.4479 32.4478 16.0002 33.0001 16.0002C33.5523 16.0002 34.0001 16.4479 34.0001 17.0002C34.0001 17.5524 33.5523 18.0002 33.0001 18.0002Z%22/%3E%3Cpath d=%22M31.3561 9.86594C30.8778 10.1421 30.2663 9.97821 29.9901 9.49992C29.714 9.02162 29.8778 8.41003 30.3561 8.13389C30.8344 7.85775 31.446 8.02162 31.7222 8.49992C31.9983 8.97821 31.8344 9.5898 31.3561 9.86594Z%22/%3E%3Cpath d=%22M30.3563 25.866C29.878 25.5899 29.7141 24.9783 29.9903 24.5C30.2664 24.0217 30.878 23.8578 31.3563 24.134C31.8346 24.4101 31.9985 25.0217 31.7223 25.5C31.4462 25.9783 30.8346 26.1422 30.3563 25.866Z%22/%3E%3Cpath d=%22M16.0001 33.0001C16.0001 32.4478 16.4478 32.0001 17.0001 32.0001C17.5524 32.0001 18.0001 32.4478 18.0001 33.0001C18.0001 33.5524 17.5524 34.0001 17.0001 34.0001C16.4478 34.0001 16.0001 33.5524 16.0001 33.0001Z%22/%3E%3Cpath d=%22M24.134 31.3566C23.8579 30.8783 24.0218 30.2667 24.5001 29.9905C24.9784 29.7144 25.59 29.8783 25.8661 30.3566C26.1422 30.8349 25.9784 31.4464 25.5001 31.7226C25.0218 31.9987 24.4102 31.8349 24.134 31.3566Z%22/%3E%3Cpath d=%22M9.86593 31.3564C9.58978 31.8347 8.97819 31.9986 8.4999 31.7224C8.02161 31.4463 7.85773 30.8347 8.13388 30.3564C8.41002 29.8781 9.02161 29.7142 9.4999 29.9904C9.97819 30.2665 10.1421 30.8781 9.86593 31.3564Z%22/%3E%3Cpath d=%22M1 18.0001C0.447715 18.0001 -3.44684e-08 17.5524 0 17.0001C3.44684e-08 16.4478 0.447715 16.0001 1 16.0001C1.55228 16.0001 2 16.4478 2 17.0001C2 17.5524 1.55228 18.0001 1 18.0001Z%22/%3E%3Cpath d=%22M3.64329 25.866C3.16499 26.1422 2.5534 25.9783 2.27726 25.5C2.00112 25.0217 2.16499 24.4101 2.64329 24.134C3.12158 23.8578 3.73317 24.0217 4.00931 24.5C4.28545 24.9783 4.12158 25.5899 3.64329 25.866Z%22/%3E%3Cpath d=%22M2.6435 9.86602C2.1652 9.58987 2.00133 8.97828 2.27747 8.49999C2.55361 8.0217 3.1652 7.85782 3.6435 8.13397C4.12179 8.41011 4.28566 9.0217 4.00952 9.49999C3.73338 9.97828 3.12179 10.1422 2.6435 9.86602Z%22/%3E%3Cpath d=%22M16.0001 1C16.0001 0.447715 16.4478 -4.87226e-08 17.0001 0C17.5524 4.87226e-08 18.0001 0.447715 18.0001 1C18.0001 1.55228 17.5524 2 17.0001 2C16.4478 2 16.0001 1.55228 16.0001 1Z%22/%3E%3Cpath d=%22M8.13398 3.64371C7.85783 3.16542 8.02171 2.55383 8.5 2.27768C8.97829 2.00154 9.58988 2.16542 9.86603 2.64371C10.1422 3.122 9.97829 3.73359 9.5 4.00973C9.02171 4.28588 8.41012 4.122 8.13398 3.64371Z%22/%3E%3C/g%3E%3C/svg%3E">
    \\<link rel="stylesheet" href="/preflight.css">
    \\<link rel="stylesheet" href="/palette.css">
    \\<link rel="stylesheet" href="/shell.css">
    \\<script type="importmap">
    \\{{"imports":{{
    \\"publr-jsx":"/runtime/publr-jsx.js",
    \\"publr":"/runtime/publr.js",
    \\"publr/dom":"/runtime/publr-dom.js",
    \\"publr/html":"/runtime/publr-html.js",
    \\"publr/runtime":"/runtime/publr-runtime.js",
    \\"publr/transport":"/runtime/publr-transport.js",
    \\"publr/query":"/runtime/publr-query.js",
    \\"publr/focus":"/runtime/publr-focus.js",
    \\"publr/position":"/runtime/publr-position.js",
    \\"publr/router":"/runtime/publr-router.js",
    \\"publr/class-merge":"/runtime/publr-class-merge.js"
    \\}}}}
    \\</script>
    \\</head>
    \\<body class="bg-background text-foreground">
    \\
;
