//! Leftovers (exact): what a Bring in run did not fit into the design system, as one
//! free canvas beside it, ready to drag in or ignore. One page, "Leftovers":
//!
//! - Colours outside the system: the most used opaque colours no palette colour covers
//!   (`coverage.json`), each a swatch filled with the colour, its uses and an example.
//! - Near-duplicates: for each palette colour, the colours the designs use within ΔE00 3
//!   of it (the documented navy beside the one kept, the three sages), each a swatch.
//! - Older type styles: the type combinations in families the plan does not use (an
//!   older generation still in the designs), each a specimen in its own face.
//! - Open questions: the plan's `unsure`, as text.
//!
//! Laid out by the engine's auto layout with the fonts the viewer has, as `build` does.
//!
//!   leftovers <plan.json> <evidence.json> <coverage.json> <out.pubd-dir>

const std = @import("std");
const engine = @import("publr_engine");
const make = @import("make.zig");
const color = @import("color.zig");

const m = engine.model;
const W = engine.pubd_write;
const Io = std.Io;
const Dir = std.Io.Dir;
const A = std.mem.Allocator;
const Value = std.json.Value;
const Builder = make.Builder;

const max_file = 64 * 1024 * 1024;
/// Colours this close to a palette colour count as its near-duplicates, when the designs
/// use them this often; greys (chroma under `near_chroma`) are left out, their near
/// shades are many and mostly noise.
const near_de = 3.0;
const near_uses = 20;
const near_chroma = 8.0;

fn obj(v: Value, key: []const u8) Value {
    if (v != .object) return .null;
    return v.object.get(key) orelse .null;
}

fn arr(v: Value, key: []const u8) []Value {
    const x = obj(v, key);
    return if (x == .array) x.array.items else &.{};
}

fn str(v: Value, key: []const u8) []const u8 {
    const x = obj(v, key);
    return if (x == .string) x.string else "";
}

fn int(v: Value) i64 {
    return switch (v) {
        .integer => |i| i,
        .float => |x| @intFromFloat(x),
        else => 0,
    };
}

fn labOf(hex: []const u8) color.Lab {
    const c = make.parseHex(hex);
    return color.lab(c.r, c.g, c.b);
}

fn readJson(io: Io, a: A, path: []const u8) !Value {
    const bytes = try Dir.cwd().readFileAlloc(io, path, a, .limited(max_file));
    return std.json.parseFromSliceLeaky(Value, a, bytes, .{});
}

/// A wrapped line of muted text `width` wide.
fn note(b: *Builder, s: []const u8, size: f32, lh: f32, width: f32) m.Node {
    var t = b.text(s, make.chrome_font, "Regular", 400, size, lh, make.muted);
    t.text.?.resize = .height;
    t.size = .{
        .x = width,
        .y = lh,
    };
    return t;
}

/// A colour swatch with its hex, a line under it and an optional note.
fn swatch(b: *Builder, hex: []const u8, caption: []const u8, extra: []const u8) !m.Node {
    const a = b.a;
    const col = make.parseHex(hex);
    var r = b.rect(hex, 120, 80, col, 10);
    if (make.luminance(col) > 0.9) {
        r.strokes = b.solid(make.line);
        r.stroke.weight = 1;
    }
    var kids = b.list();
    try kids.append(a, r);
    try kids.append(a, b.strong(hex));
    if (caption.len > 0) try kids.append(a, b.label(caption));
    if (extra.len > 0) try kids.append(a, note(b, extra, 11, 15, 120));
    return b.frame(hex, .vertical, 6, 0, kids.items);
}

pub fn run(io: Io, gpa: A, w: *Io.Writer, plan_path: []const u8, evidence_path: []const u8, coverage_path: []const u8, out_dir: []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const plan = try readJson(io, a, plan_path);
    const ev = try readJson(io, a, evidence_path);
    const cov = try readJson(io, a, coverage_path);
    var b: Builder = .{
        .a = a,
        .next = 1,
    };
    var sections: std.ArrayList(m.Node) = .empty;

    // About.
    {
        var rows = b.list();
        try rows.append(a, b.text(try std.fmt.allocPrint(a, "{s} — leftovers", .{str(plan, "name")}), make.chrome_font, "Bold", 700, 40, 48, make.ink));
        try rows.append(a, note(&b, "What Bring in did not fit into the design system: colours outside it, near-duplicates of the colours kept, the older type styles and the open questions. Drag a colour or a text into the design system beside, or select some and right-click; or leave them.", 15, 22, 1100));
        try sections.append(a, make.card(&b, "About", rows.items));
    }

    // Colours outside the system.
    const palette = arr(obj(plan, "colors"), "palette");
    {
        var swatches = b.list();
        for (arr(obj(cov, "colors_opaque"), "outside")) |o| {
            if (o != .array or o.array.items.len < 3) continue;
            const hex = if (o.array.items[0] == .string) o.array.items[0].string else continue;
            const uses = int(o.array.items[1]);
            const path = std.mem.trim(u8, if (o.array.items[2] == .string) o.array.items[2].string else "", " ->");
            try swatches.append(a, try swatch(&b, hex, try std.fmt.allocPrint(a, "used {d}×", .{uses}), path));
        }
        if (swatches.items.len > 0) {
            var rest = b.list();
            try rest.append(a, b.wrapRow("Colours", 1300, 24, swatches.items));
            try sections.append(a, make.card(&b, "Colours outside the system", try make.titled(&b, "Colours outside the system", "The opaque colours the designs use most that no palette colour covers (ΔE00 over 2), most used first, with where one is used.", rest.items)));
        }
    }

    // Near-duplicates of the palette's colours.
    {
        const used = arr(obj(obj(ev, "used"), "colors"), "list");
        var rows = b.list();
        for (palette) |p| {
            const kept = str(p, "value");
            const kl = labOf(kept);
            if (@sqrt(kl.a * kl.a + kl.b * kl.b) < near_chroma) continue;
            // Every colour the designs use, with the shades the gather folded into it.
            var found: std.ArrayList(struct {
                hex: []const u8,
                uses: i64,
            }) = .empty;
            const consider = struct {
                fn f(list: *@TypeOf(found), al: A, pal: []Value, k: []const u8, klab: color.Lab, hex: []const u8, uses: i64) !void {
                    if (hex.len != 7 or std.ascii.eqlIgnoreCase(hex, k)) return;
                    for (pal) |q| if (std.ascii.eqlIgnoreCase(str(q, "value"), hex)) return;
                    for (list.items) |x| if (std.ascii.eqlIgnoreCase(x.hex, hex)) return;
                    if (uses < near_uses or color.de2000(klab, labOf(hex)) > near_de) return;
                    try list.append(al, .{
                        .hex = hex,
                        .uses = uses,
                    });
                }
            }.f;
            for (used) |u| {
                try consider(&found, a, palette, kept, kl, str(u, "hex"), int(obj(u, "uses")));
                for (arr(u, "near")) |nv| if (nv == .string) {
                    var it = std.mem.tokenizeAny(u8, nv.string, " ×");
                    const hex = it.next() orelse continue;
                    const n = std.fmt.parseInt(i64, it.next() orelse "0", 10) catch 0;
                    try consider(&found, a, palette, kept, kl, hex, n);
                };
            }
            if (found.items.len == 0) continue;
            std.mem.sort(@TypeOf(found.items[0]), found.items, {}, struct {
                fn less(_: void, x: @TypeOf(found.items[0]), y: @TypeOf(found.items[0])) bool {
                    return x.uses > y.uses;
                }
            }.less);
            var kids = b.list();
            try kids.append(a, try swatch(&b, kept, try std.fmt.allocPrint(a, "kept · {s}", .{str(p, "name")}), ""));
            for (found.items[0..@min(found.items.len, 6)]) |x| {
                const de = color.de2000(kl, labOf(x.hex));
                try kids.append(a, try swatch(&b, x.hex, try std.fmt.allocPrint(a, "used {d}×", .{x.uses}), try std.fmt.allocPrint(a, "ΔE00 {d:.1} from {s}", .{ de, str(p, "name") })));
            }
            var row = b.frame(str(p, "name"), .horizontal, 24, 0, kids.items);
            row.layout.?.cross = .start;
            try rows.append(a, row);
        }
        if (rows.items.len > 0) {
            try sections.append(a, make.card(&b, "Near-duplicates", try make.titled(&b, "Near-duplicates", "Colours the designs use within ΔE00 3 of a palette colour: the first of each row is the one kept, the others were folded into it.", rows.items)));
        }
    }

    // Older type styles: families the plan does not use.
    {
        const sample = if (str(plan, "sample").len > 0) str(plan, "sample") else "The quick brown fox jumps over the lazy dog";
        var families: std.ArrayList([]const u8) = .empty;
        if (obj(obj(ev, "used"), "fonts") == .object) {
            var it = obj(obj(ev, "used"), "fonts").object.iterator();
            while (it.next()) |e| try families.append(a, e.key_ptr.*);
        }
        var rows = b.list();
        var shown: usize = 0;
        for (arr(obj(obj(ev, "used"), "type"), "list")) |t| {
            const font = str(t, "font");
            var family: []const u8 = "";
            for (families.items) |f| if (std.mem.startsWith(u8, font, f) and f.len > family.len) {
                family = f;
            };
            if (family.len == 0) continue;
            var planned = false;
            for (arr(plan, "fonts")) |f| planned = planned or std.mem.eql(u8, str(f, "family"), family);
            if (planned) continue;
            // "Moderat Regular 400": the face name between the family and the weight.
            const rest = std.mem.trim(u8, font[family.len..], " ");
            const space = std.mem.lastIndexOfScalar(u8, rest, ' ') orelse continue;
            const style = rest[0..space];
            const weight = std.fmt.parseInt(u16, rest[space + 1 ..], 10) catch 400;
            const size: f32 = @floatCast(switch (obj(t, "size")) {
                .integer => |i| @as(f64, @floatFromInt(i)),
                .float => |x| x,
                else => 16,
            });
            // The first variant names its line height ("size 16 lh 24 ls 0 ×2740 …").
            var lh: ?f32 = null;
            var uses: i64 = int(obj(t, "uses"));
            if (arr(t, "variants").len > 0 and arr(t, "variants")[0] == .string) {
                const v = arr(t, "variants")[0].string;
                if (std.mem.indexOf(u8, v, " lh ")) |at| {
                    var it = std.mem.tokenizeScalar(u8, v[at + 4 ..], ' ');
                    lh = std.fmt.parseFloat(f32, it.next() orelse "") catch null;
                }
                if (std.mem.indexOf(u8, v, "×")) |at| {
                    var it = std.mem.tokenizeScalar(u8, v[at + "×".len ..], ' ');
                    uses = std.fmt.parseInt(i64, it.next() orelse "0", 10) catch uses;
                }
            }
            const lh_text = if (lh) |x| try std.fmt.allocPrint(a, "{d}", .{x}) else "auto";
            const name = try std.fmt.allocPrint(a, "{s} {s} {d}/{s}", .{ family, style, size, lh_text });
            var spec = b.list();
            try spec.append(a, b.strong(try std.fmt.allocPrint(a, "{s} {s}", .{ family, style })));
            try spec.append(a, b.label(try std.fmt.allocPrint(a, "{d} / {s} · weight {d} · used {d}×", .{ size, lh_text, weight, uses })));
            var left = b.frame("spec", .vertical, 4, 0, spec.items);
            left.layout.?.width = .fixed;
            left.size = .{
                .x = 280,
                .y = 10,
            };
            var specimen = b.text(sample, family, style, weight, size, lh, make.ink);
            specimen.name = name;
            specimen.text.?.resize = .height;
            specimen.size = .{
                .x = 900,
                .y = size,
            };
            var kids = b.list();
            try kids.append(a, left);
            try kids.append(a, specimen);
            try rows.append(a, b.frame(name, .horizontal, 40, 0, kids.items));
            shown += 1;
            if (shown >= 14) break;
        }
        if (rows.items.len > 0) {
            try sections.append(a, make.card(&b, "Older type styles", try make.titled(&b, "Older type styles", "Type in families the design system does not use: the older generation still in many designs, most used first.", rows.items)));
        }
    }

    // Open questions.
    if (arr(plan, "unsure").len > 0) {
        var rows = b.list();
        try rows.append(a, b.text("Open questions", make.chrome_font, "Semi Bold", 600, 28, 36, make.ink));
        for (arr(plan, "unsure")) |u| if (u == .string) {
            var t = b.text(u.string, make.chrome_font, "Regular", 400, 14, 20, make.ink);
            t.text.?.resize = .height;
            t.size = .{
                .x = 1100,
                .y = 20,
            };
            try rows.append(a, t);
        };
        try sections.append(a, make.card(&b, "Open questions", rows.items));
    }

    const page: m.Node = .{
        .id = "lo:page",
        .kind = .page,
        .name = "Leftovers",
        .background = .{
            .r = 0.96,
            .g = 0.96,
            .b = 0.96,
        },
        .children = sections.items,
    };
    var pages = [1]m.Node{page};
    var doc: m.Document = .{
        .arena = .init(gpa),
        .name = try std.fmt.allocPrint(a, "{s} leftovers", .{str(plan, "name")}),
        .pages = &pages,
        .styles = b.styles.items,
        .glyphs = b.glyphs.items,
    };
    defer doc.arena.deinit();
    var fonts_used: std.ArrayList(m.FontRef) = .empty;
    try m.collectFonts(a, &pages[0], &fonts_used);
    doc.fonts = fonts_used.items;

    // The folder first: the fonts are found from it (`../../fonts`).
    try Dir.cwd().createDirPath(io, out_dir);
    var fonts: engine.layout.FontSet = .{};
    var font_arena: std.heap.ArenaAllocator = .init(gpa);
    defer font_arena.deinit();
    try make.loadFonts(io, gpa, font_arena.allocator(), try std.fs.path.join(a, &.{ out_dir, "..", "..", "fonts" }), &fonts);
    try make.loadFonts(io, gpa, font_arena.allocator(), try std.fs.path.join(a, &.{ out_dir, "..", "..", "fonts-fallback" }), &fonts);
    const rep = try engine.relayout.relayout(gpa, &doc, .{
        .fonts = &fonts,
    });
    // One column, the sections stacked.
    var top: f32 = 0;
    for (pages[0].children) |*s| {
        s.transform = .{
            .a = 1,
            .b = 0,
            .c = 0,
            .d = 1,
            .e = 0,
            .f = top,
        };
        top += s.size.y + 96;
    }
    const doc_json = try W.toJson(gpa, &doc);
    defer gpa.free(doc_json);
    try Dir.cwd().createDirPath(io, out_dir);
    try Dir.cwd().writeFile(io, .{
        .sub_path = try std.fs.path.join(a, &.{ out_dir, "document.json" }),
        .data = doc_json,
    });
    try w.print("{s}: {d} sections, layout {d} nodes / {d} texts ({d} unmeasured), {d} bytes\n", .{ out_dir, sections.items.len, rep.nodes, rep.texts, rep.unmeasured, doc_json.len });
}
