//! Build (exact): one `.pubd` from a design-system plan. One page, "Design system", a
//! frame per section (Colours, Typography, Spacing, Radii, Effects, Breakpoints, Icons,
//! Components), laid out by the engine's own auto layout. Every token is a Pubd
//! variable (pubd/SPEC.md "Variables"): the palette, the colour roles with a mode per
//! colour context (light, dark) aliasing the palette, the fonts and type sizes, spacing,
//! radii and breakpoints, named as the source names them, each with its token as web
//! code syntax. The swatches, specimens, spacing bars and radius samples are bound to
//! them, and the colours, type and shadows are also Pubd styles (their values bound to
//! the same variables), so the editor's Styles panel lists them. The whole system in
//! Publr's shape (tokens in its naming, the type scale, the colour roles and contexts)
//! is kept on the page as host data (`data.publr.designSystem`).
//!
//! Icons and components are carried over from the source: the node a plan names is
//! copied with its resolved children (instances keep their look; their main is not in
//! this file, so `component` is dropped), glyph outlines renumbered, images left out.
//!
//!   build <plan.json> <out.pubd-dir>

const std = @import("std");
const engine = @import("publr_engine");
const Source = @import("source.zig").Source;

const m = engine.model;
const W = engine.pubd_write;
const Io = std.Io;
const Dir = std.Io.Dir;
const A = std.mem.Allocator;
const Value = std.json.Value;

const max_file = 64 * 1024 * 1024;

// The spec canvas's own look (not the system's): neutral greys and Inter.
pub const chrome_font = "Inter";
pub const ink: m.Color = .{
    .r = 0.1,
    .g = 0.1,
    .b = 0.11,
};
pub const muted: m.Color = .{
    .r = 0.45,
    .g = 0.45,
    .b = 0.48,
};
pub const line: m.Color = .{
    .r = 0.88,
    .g = 0.88,
    .b = 0.9,
};
pub const white: m.Color = .{
    .r = 1,
    .g = 1,
    .b = 1,
};

pub const Builder = struct {
    a: A,
    next: u32 = 1,
    styles: std.ArrayList(m.Style) = .empty,
    glyphs: std.ArrayList([]const u8) = .empty,
    collections: std.ArrayList(m.Collection) = .empty,
    variables: std.ArrayList(m.Variable) = .empty,
    /// Variable ids by token (palette and role colours), and by name in a collection.
    tok_var: std.StringHashMapUnmanaged([]const u8) = .empty,
    by_name: std.StringHashMapUnmanaged([]const u8) = .empty,
    /// Source variables (`Collection/name`) to ours: what a carried-over node bound to
    /// one is bound to here.
    src_map: std.StringHashMapUnmanaged([]const u8) = .empty,

    /// The source variables a plan entry maps (`variable`, and the values of
    /// `variables`) to our variable `vid`; the first claim stands.
    pub fn mapSource(b: *Builder, v: Value, vid: []const u8) !void {
        const one = str(v, "variable");
        if (one.len > 0 and !b.src_map.contains(one)) try b.src_map.put(b.a, one, vid);
        const vs = obj(v, "variables");
        if (vs == .object) {
            var it = vs.object.iterator();
            while (it.next()) |e| if (e.value_ptr.* == .string and !b.src_map.contains(e.value_ptr.string)) try b.src_map.put(b.a, e.value_ptr.string, vid);
        }
    }

    /// A collection with these modes (`[id, name]`, the first the default).
    pub fn collection(b: *Builder, cid: []const u8, name: []const u8, modes: []const [2][]const u8) !void {
        for (b.collections.items) |c| if (std.mem.eql(u8, c.id, cid)) return;
        const ms = try b.a.alloc(m.VariableMode, modes.len);
        for (ms, modes) |*x, md| x.* = .{
            .id = md[0],
            .name = md[1],
        };
        try b.collections.append(b.a, .{
            .id = cid,
            .name = name,
            .modes = ms,
        });
    }

    pub const VarSpec = struct {
        collection: []const u8,
        name: []const u8,
        type: m.VariableType,
        /// `[mode id, value as Pubd JSON]`.
        values: []const [2][]const u8,
        token: []const u8 = "",
        scopes: []const []const u8 = &.{},
        description: []const u8 = "",
    };

    /// A variable (one per name in a collection: a second ask returns the first).
    pub fn variable(b: *Builder, v: VarSpec) ![]const u8 {
        const key = try std.fmt.allocPrint(b.a, "{s}\x00{s}", .{ v.collection, v.name });
        if (b.by_name.get(key)) |known| return known;
        const vid = try std.fmt.allocPrint(b.a, "ds:v{d}", .{b.variables.items.len + 1});
        const vals = try b.a.alloc(m.VariableValue, v.values.len);
        for (vals, v.values) |*x, y| x.* = .{
            .mode = y[0],
            .value = y[1],
        };
        try b.variables.append(b.a, .{
            .id = vid,
            .name = v.name,
            .collection = v.collection,
            .type = v.type,
            .description = v.description,
            .values = vals,
            .scopes = v.scopes,
            .code = .{
                .web = if (v.token.len > 0) try std.fmt.allocPrint(b.a, "var(--{s})", .{v.token}) else "",
            },
        });
        try b.by_name.put(b.a, key, vid);
        return vid;
    }

    /// A number variable in a one-mode collection.
    pub fn numVar(b: *Builder, col: []const u8, mode: []const u8, name: []const u8, v: f32, token: []const u8, scopes: []const []const u8, description: []const u8) ![]const u8 {
        const vals = try b.a.alloc([2][]const u8, 1);
        vals[0] = .{ mode, try std.fmt.allocPrint(b.a, "{d}", .{v}) };
        return b.variable(.{
            .collection = col,
            .name = name,
            .type = .number,
            .values = vals,
            .token = token,
            .scopes = scopes,
            .description = description,
        });
    }

    pub fn bind(b: *Builder, key: []const u8, vid: []const u8) ![]m.VarBinding {
        const out = try b.a.alloc(m.VarBinding, 1);
        out[0] = .{
            .key = key,
            .variable = vid,
        };
        return out;
    }

    pub fn id(b: *Builder) []const u8 {
        const s = std.fmt.allocPrint(b.a, "ds:{d}", .{b.next}) catch unreachable;
        b.next += 1;
        return s;
    }

    pub fn solid(b: *Builder, c: m.Color) []m.Paint {
        const ps = b.a.alloc(m.Paint, 1) catch unreachable;
        ps[0] = .{
            .kind = .solid,
            .color = c,
        };
        return ps;
    }

    pub fn frame(b: *Builder, name: []const u8, mode: m.LayoutMode, gap: f32, pad: f32, children: []m.Node) m.Node {
        return .{
            .id = b.id(),
            .kind = .frame,
            .name = name,
            .children = children,
            .layout = .{
                .mode = mode,
                .gap = gap,
                .padding = .{ pad, pad, pad, pad },
                .width = .hug,
                .height = .hug,
            },
        };
    }

    /// A row that wraps at `width`.
    pub fn wrapRow(b: *Builder, name: []const u8, width: f32, gap: f32, children: []m.Node) m.Node {
        var n = b.frame(name, .horizontal, gap, 0, children);
        n.layout.?.wrap = true;
        n.layout.?.cross_gap = gap;
        n.layout.?.width = .fixed;
        n.size = .{
            .x = width,
            .y = 10,
        };
        return n;
    }

    pub fn text(b: *Builder, s: []const u8, family: []const u8, font_style: []const u8, weight: u16, size: f32, lh: ?f32, c: m.Color) m.Node {
        return .{
            .id = b.id(),
            .kind = .text,
            .name = s[0..@min(s.len, 40)],
            .fills = b.solid(c),
            .size = .{
                .x = 10,
                .y = 10,
            },
            .text = .{
                .text = s,
                .resize = .width_and_height,
                .style = .{
                    .family = family,
                    .font_style = font_style,
                    .weight = weight,
                    .size = size,
                    .line_height = if (lh) |x| .{
                        .px = x,
                    } else .auto,
                },
            },
        };
    }

    pub fn label(b: *Builder, s: []const u8) m.Node {
        return b.text(s, chrome_font, "Regular", 400, 13, 18, muted);
    }

    pub fn strong(b: *Builder, s: []const u8) m.Node {
        return b.text(s, chrome_font, "Semi Bold", 600, 14, 20, ink);
    }

    pub fn rect(b: *Builder, name: []const u8, w: f32, h: f32, c: m.Color, r: f32) m.Node {
        return .{
            .id = b.id(),
            .kind = .rectangle,
            .name = name,
            .size = .{
                .x = w,
                .y = h,
            },
            .fills = b.solid(c),
            .radius = .{ r, r, r, r },
        };
    }

    fn style(b: *Builder, kind: m.StyleKind, name: []const u8, description: []const u8, v: W.StyleValue) ![]const u8 {
        const sid = try std.fmt.allocPrint(b.a, "ds:s{d}", .{b.styles.items.len + 1});
        try b.styles.append(b.a, .{
            .id = sid,
            .kind = kind,
            .name = name,
            .description = description,
            .value = try W.styleValueJson(b.a, v),
        });
        return sid;
    }

    pub fn list(b: *Builder) std.ArrayList(m.Node) {
        _ = b;
        return .empty;
    }
};

fn str(v: Value, key: []const u8) []const u8 {
    if (v != .object) return "";
    const x = v.object.get(key) orelse return "";
    return if (x == .string) x.string else "";
}

fn num(v: Value, key: []const u8) ?f32 {
    if (v != .object) return null;
    const x = v.object.get(key) orelse return null;
    return switch (x) {
        .integer => |i| @floatFromInt(i),
        .float => |f| @floatCast(f),
        else => null,
    };
}

fn arr(v: Value, key: []const u8) []Value {
    if (v != .object) return &.{};
    const x = v.object.get(key) orelse return &.{};
    return if (x == .array) x.array.items else &.{};
}

fn obj(v: Value, key: []const u8) Value {
    if (v != .object) return .null;
    return v.object.get(key) orelse .null;
}

pub fn parseHex(s: []const u8) m.Color {
    const h = if (s.len > 0 and s[0] == '#') s[1..] else s;
    const byte = struct {
        fn f(x: []const u8) f32 {
            return @as(f32, @floatFromInt(std.fmt.parseInt(u8, x, 16) catch 0)) / 255;
        }
    }.f;
    if (h.len < 6) return .{};
    return .{
        .r = byte(h[0..2]),
        .g = byte(h[2..4]),
        .b = byte(h[4..6]),
        .a = if (h.len >= 8) byte(h[6..8]) else 1,
    };
}

pub fn luminance(c: m.Color) f32 {
    return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b;
}

/// "Saans", 500 → the face name a design tool shows.
pub fn faceName(weight: u16, italic: bool, given: []const u8) []const u8 {
    if (given.len > 0) return given;
    const n: []const u8 = switch (weight) {
        100 => "Thin",
        200 => "Extra Light",
        300 => "Light",
        500 => "Medium",
        600 => "Semi Bold",
        700 => "Bold",
        800 => "Extra Bold",
        900 => "Black",
        else => "Regular",
    };
    return if (italic) (if (weight == 400) "Italic" else n) else n;
}

/// Who said so, in a line: the plan's evidence.
fn evidenceLine(a: A, v: Value) []const u8 {
    const e = obj(v, "evidence");
    const conf = num(v, "confidence");
    var out: std.ArrayList(u8) = .empty;
    if (e == .string) out.appendSlice(a, e.string) catch {};
    if (conf) |c| out.print(a, "{s}confidence {d:.2}", .{ if (out.items.len > 0) " · " else "", c }) catch {};
    return out.items;
}

pub fn run(io: Io, gpa: A, w: *Io.Writer, plan_path: []const u8, out_dir: []const u8) !void {
    const t0 = Io.Timestamp.now(io, .awake);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const json = try Dir.cwd().readFileAlloc(io, plan_path, a, .limited(max_file));
    const plan = try std.json.parseFromSliceLeaky(Value, a, json, .{});
    var b: Builder = .{
        .a = a,
    };
    var sections: std.ArrayList(m.Node) = .empty;
    var tokens: std.ArrayList([2][]const u8) = .empty;

    try sections.append(a, try header(&b, plan));
    if (try colors(&b, plan, &tokens)) |n| try sections.append(a, n);
    if (try typography(&b, plan, &tokens)) |n| try sections.append(a, n);
    if (try scaleSection(&b, plan, "spacing", "Spacing", &tokens)) |n| try sections.append(a, n);
    if (try scaleSection(&b, plan, "radii", "Radii", &tokens)) |n| try sections.append(a, n);
    if (try effects(&b, plan, &tokens)) |n| try sections.append(a, n);
    if (try breakpoints(&b, plan, &tokens)) |n| try sections.append(a, n);

    // Icons and components come from the source file.
    const src_path = str(plan, "source");
    var src: ?*Source = null;
    defer if (src) |s| s.deinit();
    if (arr(plan, "icons").len > 0 or arr(plan, "components").len > 0) src = try Source.open(io, gpa, src_path);
    var carry: Carry = .{
        .b = &b,
        .gpa = gpa,
    };
    defer carry.deinit();
    carry.src = src;
    if (src) |s| {
        // Modes carried-over nodes set on the source's role collection (Light, Dark)
        // become the matching context's mode here.
        const roles_name = str(obj(plan, "collections"), "roles");
        for (s.collections) |sc| if (roles_name.len > 0 and std.mem.eql(u8, sc.name, roles_name)) for (sc.modes) |md| {
            for (arr(plan, "contexts")) |cx| if (std.mem.eql(u8, str(cx, "mode"), md.name)) {
                try carry.modes.put(a, try std.fmt.allocPrint(a, "{s}\x00{s}", .{ sc.id, md.id }), .{
                    .collection = "ds:c-roles",
                    .mode = try std.fmt.allocPrint(a, "ds:m-{s}", .{str(cx, "key")}),
                });
            };
        };
        if (try carried(&b, &carry, s, plan, "icons", "Icons")) |n| try sections.append(a, n);
        if (try carried(&b, &carry, s, plan, "components", "Components")) |n| try sections.append(a, n);
    }
    if (arr(plan, "unsure").len > 0) {
        var rows = b.list();
        try rows.append(a, b.text("Open questions", chrome_font, "Semi Bold", 600, 28, 36, ink));
        for (arr(plan, "unsure")) |u| if (u == .string) {
            var t = b.text(u.string, chrome_font, "Regular", 400, 14, 20, ink);
            t.text.?.resize = .height;
            t.size = .{
                .x = 1100,
                .y = 20,
            };
            try rows.append(a, t);
        };
        try sections.append(a, card(&b, "Open questions", rows.items));
    }

    // The page and its document.
    var page: m.Node = .{
        .id = "ds:page",
        .kind = .page,
        .name = "Design system",
        .background = .{
            .r = 0.96,
            .g = 0.96,
            .b = 0.96,
        },
        .children = sections.items,
    };
    page.data = try systemData(a, plan, tokens.items);
    var pages = [1]m.Node{page};
    var doc: m.Document = .{
        .arena = .init(gpa),
        .name = try std.fmt.allocPrint(a, "{s} design system", .{str(plan, "name")}),
        .pages = &pages,
        .styles = b.styles.items,
        .glyphs = b.glyphs.items,
        .collections = b.collections.items,
        .variables = b.variables.items,
    };
    defer doc.arena.deinit();
    // Every bound field to what its variable is worth there (carried-over nodes bound to
    // a token whose value differs a little, a near-duplicate navy, take the token's).
    const resolved_fields = try engine.pubd_vars.resolveDocument(gpa, &doc);
    var fonts_used: std.ArrayList(m.FontRef) = .empty;
    try m.collectFonts(a, &pages[0], &fonts_used);
    doc.fonts = fonts_used.items;

    // Lay out with the fonts the viewer will have (`pe view` looks beside the
    // document's folder), then stack the sections.
    try Dir.cwd().createDirPath(io, out_dir);
    var fonts: engine.layout.FontSet = .{};
    var font_arena: std.heap.ArenaAllocator = .init(gpa);
    defer font_arena.deinit();
    const fdir = try std.fs.path.join(a, &.{ out_dir, "..", "..", "fonts" });
    try loadFonts(io, gpa, font_arena.allocator(), fdir, &fonts);
    const fb = try std.fs.path.join(a, &.{ out_dir, "..", "..", "fonts-fallback" });
    try loadFonts(io, gpa, font_arena.allocator(), fb, &fonts);
    const rep = try engine.relayout.relayout(gpa, &doc, .{
        .fonts = &fonts,
    });
    // Sections packed into three columns, each into the shortest so far.
    var tops = [3]f32{ 0, 0, 0 };
    var widths = [3]f32{ 0, 0, 0 };
    var col_of = try a.alloc(usize, pages[0].children.len);
    for (pages[0].children, 0..) |*s, i| {
        var best: usize = 0;
        for (tops, 0..) |t, k| if (t < tops[best]) {
            best = k;
        };
        col_of[i] = best;
        widths[best] = @max(widths[best], s.size.x);
        s.transform = .{
            .a = 1,
            .b = 0,
            .c = 0,
            .d = 1,
            .e = 0,
            .f = tops[best],
        };
        tops[best] += s.size.y + 96;
    }
    for (pages[0].children, 0..) |*s, i| {
        var x: f32 = 0;
        for (0..col_of[i]) |k| x += widths[k] + 96;
        s.transform.e = x;
    }
    const doc_json = try W.toJson(gpa, &doc);
    defer gpa.free(doc_json);
    try Dir.cwd().createDirPath(io, out_dir);
    try Dir.cwd().writeFile(io, .{
        .sub_path = try std.fs.path.join(a, &.{ out_dir, "document.json" }),
        .data = doc_json,
    });
    try w.print("{s}: {d} sections, {d} collections, {d} variables, {d} styles, {d} tokens, {d} nodes carried over ({d} skipped; their source variables: {d} rebound to the system's, {d} not in it), {d} fields changed on resolving, layout {d} nodes / {d} texts ({d} unmeasured), {d} bytes, {d} ms\n", .{
        out_dir,
        sections.items.len,
        b.collections.items.len,
        b.variables.items.len,
        b.styles.items.len,
        tokens.items.len,
        carry.copied,
        carry.missing,
        carry.rebound,
        carry.dropped,
        resolved_fields,
        rep.nodes,
        rep.texts,
        rep.unmeasured,
        doc_json.len,
        @divTrunc(t0.untilNow(io, .awake).nanoseconds, std.time.ns_per_ms),
    });
}

pub fn loadFonts(io: Io, gpa: A, fa: A, dir: []const u8, set: *engine.layout.FontSet) !void {
    var d = Dir.cwd().openDir(io, dir, .{
        .iterate = true,
    }) catch return;
    defer d.close(io);
    var walker = try d.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |e| {
        if (e.kind != .file or !engine.fonts.isFontFile(e.basename)) continue;
        const p = try std.fs.path.join(fa, &.{ dir, e.path });
        const bytes = Dir.cwd().readFileAlloc(io, p, fa, .limited(64 * 1024 * 1024)) catch continue;
        _ = try engine.fonts.add(set, gpa, fa, bytes, if (std.mem.indexOf(u8, dir, "fallback") != null) .fallback else .face);
    }
}

/// A section: a white card with a title.
pub fn card(b: *Builder, name: []const u8, children: []m.Node) m.Node {
    var n = b.frame(name, .vertical, 32, 56, children);
    n.fills = b.solid(white);
    n.radius = .{ 24, 24, 24, 24 };
    return n;
}

pub fn titled(b: *Builder, title: []const u8, note: []const u8, rest: []const m.Node) ![]m.Node {
    var out = b.list();
    try out.append(b.a, b.text(title, chrome_font, "Semi Bold", 600, 40, 48, ink));
    if (note.len > 0) {
        var t = b.text(note, chrome_font, "Regular", 400, 15, 22, muted);
        t.text.?.resize = .height;
        t.size = .{
            .x = 1100,
            .y = 22,
        };
        try out.append(b.a, t);
    }
    try out.appendSlice(b.a, rest);
    return out.items;
}

fn header(b: *Builder, plan: Value) !m.Node {
    var rows = b.list();
    try rows.append(b.a, b.text(try std.fmt.allocPrint(b.a, "{s} — design system", .{str(plan, "name")}), chrome_font, "Bold", 700, 56, 64, ink));
    var t = b.text(str(plan, "summary"), chrome_font, "Regular", 400, 18, 28, muted);
    t.text.?.resize = .height;
    t.size = .{
        .x = 1100,
        .y = 28,
    };
    try rows.append(b.a, t);
    try rows.append(b.a, b.label(try std.fmt.allocPrint(b.a, "Brought in from {s}. Every token below names its evidence: declared in the file, used in its designs, or both.", .{std.fs.path.basename(str(plan, "source"))})));
    return card(b, "About", rows.items);
}

/// The colour contexts (light, dark, ...): the plan's, else one default. Each is a mode
/// of the Roles collection, `[key, label]`.
fn contextsOf(a: A, plan: Value) ![]const [2][]const u8 {
    var out: std.ArrayList([2][]const u8) = .empty;
    for (arr(plan, "contexts")) |c| try out.append(a, .{ str(c, "key"), if (str(c, "label").len > 0) str(c, "label") else str(c, "key") });
    if (out.items.len == 0) try out.append(a, .{ "default", "Default" });
    return out.items;
}

/// The variable's description: the plan's evidence and the source variable it maps.
fn varNote(a: A, v: Value) ![]const u8 {
    const src = str(v, "variable");
    const ev = evidenceLine(a, v);
    if (src.len == 0) return ev;
    return std.fmt.allocPrint(a, "From {s}. {s}", .{ src, ev });
}

/// A source variable's name without its collection (`Spacers/Gap & Padding/large` →
/// `Gap & Padding/large`).
fn shortName(full: []const u8) []const u8 {
    const i = std.mem.indexOfScalar(u8, full, '/') orelse return full;
    return full[i + 1 ..];
}

fn hexJson(a: A, hex: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "\"{s}\"", .{hex});
}

fn colors(b: *Builder, plan: Value, tokens: *std.ArrayList([2][]const u8)) !?m.Node {
    const c = obj(plan, "colors");
    const palette = arr(c, "palette");
    if (palette.len == 0) return null;
    const a = b.a;
    const names = obj(plan, "collections");
    const pal_col = "ds:c-palette";
    try b.collection(pal_col, if (str(names, "palette").len > 0) str(names, "palette") else "Palette", &.{.{ "ds:m-palette", "Value" }});
    var swatches = b.list();
    for (palette) |p| {
        const hex = str(p, "value");
        const col = parseHex(hex);
        const tok = str(p, "token");
        try tokens.append(a, .{ tok, hex });
        const vid = try b.variable(.{
            .collection = pal_col,
            .name = if (str(p, "varName").len > 0) str(p, "varName") else str(p, "name"),
            .type = .color,
            .values = &.{.{ "ds:m-palette", try hexJson(a, hex) }},
            .token = tok,
            .description = try varNote(a, p),
        });
        try b.tok_var.put(a, tok, vid);
        try b.mapSource(p, vid);
        const paint = b.solid(col);
        paint[0].variable = vid;
        const sid = try b.style(.fill, try std.fmt.allocPrint(a, "Palette/{s}", .{str(p, "name")}), evidenceLine(a, p), .{
            .fill = paint,
        });
        var sw = b.rect(str(p, "name"), 176, 104, col, 12);
        sw.fills = paint;
        sw.styles.fill = sid;
        if (luminance(col) > 0.9) {
            sw.strokes = b.solid(line);
            sw.stroke.weight = 1;
        }
        // The roles this colour plays.
        var roles: std.ArrayList(u8) = .empty;
        for (arr(c, "roles")) |r| if (std.mem.eql(u8, str(r, "palette"), tok)) {
            try roles.print(a, "{s}{s}", .{ if (roles.items.len > 0) ", " else "", str(r, "role") });
        };
        var kids = b.list();
        try kids.append(a, sw);
        try kids.append(a, b.strong(str(p, "name")));
        try kids.append(a, b.label(try std.fmt.allocPrint(a, "{s} · {s}", .{ hex, tok })));
        if (str(p, "variable").len > 0) try kids.append(a, b.text(try std.fmt.allocPrint(a, "← {s}", .{str(p, "variable")}), chrome_font, "Regular", 400, 11, 15, muted));
        if (roles.items.len > 0) try kids.append(a, b.text(roles.items, chrome_font, "Medium", 500, 12, 16, ink));
        var ev = b.text(evidenceLine(a, p), chrome_font, "Regular", 400, 11, 15, muted);
        ev.text.?.resize = .height;
        ev.size = .{
            .x = 176,
            .y = 15,
        };
        try kids.append(a, ev);
        try swatches.append(a, b.frame(str(p, "name"), .vertical, 6, 0, kids.items));
    }

    // Roles: a variable each, a mode per context, aliasing the palette.
    const contexts = try contextsOf(a, plan);
    const role_col = "ds:c-roles";
    {
        const modes = try a.alloc([2][]const u8, contexts.len);
        for (modes, contexts) |*md, cx| md.* = .{ try std.fmt.allocPrint(a, "ds:m-{s}", .{cx[0]}), cx[1] };
        try b.collection(role_col, if (str(names, "roles").len > 0) str(names, "roles") else "Roles", modes);
    }
    const Role = struct {
        r: Value,
        vid: []const u8,
        /// Per context: the palette token and its colour.
        targets: [][]const u8,
        hexes: [][]const u8,
    };
    var roles: std.ArrayList(Role) = .empty;
    for (arr(c, "roles")) |r| {
        const targets = try a.alloc([]const u8, contexts.len);
        const hexes = try a.alloc([]const u8, contexts.len);
        const vals = try a.alloc([2][]const u8, contexts.len);
        for (contexts, 0..) |cx, i| {
            // A context names a palette token, or (a colour the palette does not hold,
            // such as a translucent overlay) a hex value.
            var target = str(r, "palette");
            var hex: []const u8 = str(r, "value");
            if (i > 0) {
                const t = str(obj(r, "contexts"), cx[0]);
                if (t.len > 0 and t[0] == '#') {
                    target = "";
                    hex = t;
                } else if (t.len > 0) target = t;
            }
            targets[i] = target;
            for (palette) |p| if (std.mem.eql(u8, str(p, "token"), target)) {
                hex = str(p, "value");
            };
            hexes[i] = hex;
            const mode = try std.fmt.allocPrint(a, "ds:m-{s}", .{cx[0]});
            vals[i] = .{ mode, if (b.tok_var.get(target)) |pv| try std.fmt.allocPrint(a, "{{\"alias\":\"{s}\"}}", .{pv}) else try hexJson(a, hex) };
            const role_token = if (i == 0) try std.fmt.allocPrint(a, "color-{s}", .{str(r, "role")}) else try std.fmt.allocPrint(a, "color-{s}-{s}", .{ cx[0], str(r, "role") });
            try tokens.append(a, .{ role_token, if (target.len > 0) try std.fmt.allocPrint(a, "var(--{s})", .{target}) else hex });
        }
        const vid = try b.variable(.{
            .collection = role_col,
            .name = if (str(r, "varName").len > 0) str(r, "varName") else str(r, "label"),
            .type = .color,
            .values = vals,
            .token = try std.fmt.allocPrint(a, "color-{s}", .{str(r, "role")}),
            .description = try varNote(a, r),
        });
        try b.tok_var.put(a, try std.fmt.allocPrint(a, "color-{s}", .{str(r, "role")}), vid);
        try b.mapSource(r, vid);
        try roles.append(a, .{
            .r = r,
            .vid = vid,
            .targets = targets,
            .hexes = hexes,
        });
    }
    var role_rows = b.list();
    for (roles.items) |ro| {
        const r = ro.r;
        const target = ro.targets[0];
        const col = parseHex(ro.hexes[0]);
        const role_token = try std.fmt.allocPrint(a, "color-{s}", .{str(r, "role")});
        const paint = b.solid(col);
        paint[0].variable = ro.vid;
        const sid = try b.style(.fill, try std.fmt.allocPrint(a, "Role/{s}", .{str(r, "role")}), evidenceLine(a, r), .{
            .fill = paint,
        });
        var sw = b.rect(str(r, "role"), 48, 48, col, 24);
        sw.fills = paint;
        sw.styles.fill = sid;
        sw.strokes = b.solid(line);
        sw.stroke.weight = 1;
        var kids = b.list();
        try kids.append(a, sw);
        var txt = b.list();
        var head: std.ArrayList(u8) = .empty;
        try head.print(a, "{s} → {s}", .{ role_token, if (target.len > 0) target else ro.hexes[0] });
        for (contexts[1..], ro.targets[1..]) |cx, t| if (!std.mem.eql(u8, t, target)) try head.print(a, " · {s}: {s}", .{ cx[0], t });
        try txt.append(a, b.strong(head.items));
        var why = b.text(try std.fmt.allocPrint(a, "{s}{s}{s} — {s}", .{ if (str(r, "variable").len > 0) "← " else "", str(r, "variable"), if (str(r, "variable").len > 0) ". " else "", try std.fmt.allocPrint(a, "{s} {s}", .{ str(r, "reason"), evidenceLine(a, r) }) }), chrome_font, "Regular", 400, 12, 17, muted);
        why.text.?.resize = .height;
        why.size = .{
            .x = 420,
            .y = 17,
        };
        try txt.append(a, why);
        try kids.append(a, b.frame("text", .vertical, 2, 0, txt.items));
        var row = b.frame(str(r, "role"), .horizontal, 14, 0, kids.items);
        row.layout.?.cross = .center;
        try role_rows.append(a, row);
    }
    // Every context side by side: the same role variables, the frame in that mode.
    var ctx_cards = b.list();
    if (contexts.len > 1 and roles.items.len > 0) for (contexts, 0..) |cx, i| {
        var chips = b.list();
        for (roles.items) |ro| {
            const col = parseHex(ro.hexes[i]);
            const paint = b.solid(col);
            paint[0].variable = ro.vid;
            var sw = b.rect(str(ro.r, "role"), 40, 40, col, 20);
            sw.fills = paint;
            sw.strokes = b.solid(line);
            sw.stroke.weight = 1;
            var ck = b.list();
            try ck.append(a, sw);
            var lab = b.text(str(ro.r, "role"), chrome_font, "Regular", 400, 10, 13, muted);
            lab.text.?.resize = .height;
            lab.size = .{
                .x = 72,
                .y = 13,
            };
            try ck.append(a, lab);
            var chip = b.frame(str(ro.r, "role"), .vertical, 4, 0, ck.items);
            chip.layout.?.cross = .center;
            try chips.append(a, chip);
        }
        var inner = b.list();
        try inner.append(a, b.strong(try std.fmt.allocPrint(a, "{s} (mode of {s})", .{ cx[1], if (str(names, "roles").len > 0) str(names, "roles") else "Roles" })));
        try inner.append(a, b.wrapRow("roles", 620, 10, chips.items));
        var cardn = b.frame(cx[1], .vertical, 12, 16, inner.items);
        cardn.radius = .{ 16, 16, 16, 16 };
        cardn.strokes = b.solid(line);
        cardn.stroke.weight = 1;
        const ms = try a.alloc(m.ModeChoice, 1);
        ms[0] = .{
            .collection = role_col,
            .mode = try std.fmt.allocPrint(a, "ds:m-{s}", .{cx[0]}),
        };
        cardn.modes = ms;
        try ctx_cards.append(a, cardn);
    };
    var rest = b.list();
    try rest.append(a, b.text("Palette", chrome_font, "Semi Bold", 600, 22, 28, ink));
    try rest.append(a, b.wrapRow("Palette", 1300, 28, swatches.items));
    if (role_rows.items.len > 0) {
        try rest.append(a, b.text("Semantic roles", chrome_font, "Semi Bold", 600, 22, 28, ink));
        try rest.append(a, b.wrapRow("Roles", 1300, 24, role_rows.items));
    }
    if (ctx_cards.items.len > 0) {
        try rest.append(a, b.text("Colour contexts", chrome_font, "Semi Bold", 600, 22, 28, ink));
        try rest.append(a, b.label("The same role variables in frames set to each mode."));
        try rest.append(a, b.wrapRow("Contexts", 1300, 24, ctx_cards.items));
    }
    return card(b, "Colours", try titled(b, "Colours", str(c, "note"), rest.items));
}

fn typography(b: *Builder, plan: Value, tokens: *std.ArrayList([2][]const u8)) !?m.Node {
    const scale = arr(plan, "typeScale");
    if (scale.len == 0) return null;
    const a = b.a;
    const type_col = "ds:c-type";
    try b.collection(type_col, if (str(obj(plan, "collections"), "type").len > 0) str(obj(plan, "collections"), "type") else "Typography", &.{.{ "ds:m-type", "Value" }});
    // Fonts and roles.
    var font_cards = b.list();
    var family_var: std.StringHashMapUnmanaged([]const u8) = .empty;
    for (arr(plan, "fonts")) |f| {
        const fam = str(f, "family");
        try tokens.append(a, .{ str(f, "token"), try std.fmt.allocPrint(a, "\"{s}\", {s}", .{ fam, if (str(f, "fallback").len > 0) str(f, "fallback") else "sans-serif" }) });
        const fv = try b.variable(.{
            .collection = type_col,
            .name = if (str(f, "variable").len > 0) shortName(str(f, "variable")) else try std.fmt.allocPrint(a, "Font family/{s}", .{fam}),
            .type = .string,
            .values = &.{.{ "ds:m-type", try std.fmt.allocPrint(a, "\"{s}\"", .{fam}) }},
            .token = str(f, "token"),
            .scopes = &.{"font-family"},
            .description = try varNote(a, f),
        });
        if (!family_var.contains(fam)) try family_var.put(a, fam, fv);
        try b.mapSource(f, fv);
        var kids = b.list();
        const w0: u16 = if (arr(f, "weights").len > 0) @intCast(arr(f, "weights")[0].integer) else 400;
        try kids.append(a, b.text("Aa", fam, faceName(w0, false, ""), w0, 72, 80, ink));
        try kids.append(a, b.strong(fam));
        var ws: std.ArrayList(u8) = .empty;
        for (arr(f, "weights")) |x| try ws.print(a, "{s}{d}", .{ if (ws.items.len > 0) ", " else "", x.integer });
        try kids.append(a, b.label(try std.fmt.allocPrint(a, "{s} · weights {s}", .{ str(f, "token"), ws.items })));
        var ev = b.text(evidenceLine(a, f), chrome_font, "Regular", 400, 11, 15, muted);
        ev.text.?.resize = .height;
        ev.size = .{
            .x = 300,
            .y = 15,
        };
        try kids.append(a, ev);
        try font_cards.append(a, b.frame(fam, .vertical, 6, 0, kids.items));
    }
    for (arr(plan, "fontRoles")) |r| try tokens.append(a, .{ try std.fmt.allocPrint(a, "font-{s}", .{str(r, "role")}), try std.fmt.allocPrint(a, "var(--{s})", .{str(r, "font")}) });

    var rows = b.list();
    const sample = if (str(plan, "sample").len > 0) str(plan, "sample") else "The quick brown fox jumps over the lazy dog";
    for (scale) |e| {
        const role = str(e, "fontRole");
        var family: []const u8 = "";
        for (arr(plan, "fontRoles")) |r| if (std.mem.eql(u8, str(r, "role"), role)) {
            for (arr(plan, "fonts")) |f| if (std.mem.eql(u8, str(f, "token"), str(r, "font"))) {
                family = str(f, "family");
            };
        };
        if (str(e, "family").len > 0) family = str(e, "family");
        const weight: u16 = @intFromFloat(num(e, "weight") orelse 400);
        const size = num(e, "size") orelse 16;
        const lh = num(e, "lineHeight");
        const ls = num(e, "letterSpacing") orelse 0;
        const tt = str(e, "textTransform");
        const fs = faceName(weight, false, str(e, "fontStyle"));
        // The entry's sizes as variables (one per name: entries sharing a size share it).
        const vs = obj(e, "variables");
        var binds: std.ArrayList(m.VarBinding) = .empty;
        if (family_var.get(family)) |fv| try binds.append(a, .{
            .key = "family",
            .variable = fv,
        });
        try binds.append(a, .{
            .key = "size",
            .variable = try b.numVar(type_col, "ds:m-type", if (str(vs, "size").len > 0) shortName(str(vs, "size")) else try std.fmt.allocPrint(a, "Font size/{d}", .{size}), size, "", &.{"font-size"}, if (str(vs, "size").len > 0) try std.fmt.allocPrint(a, "From {s}.", .{str(vs, "size")}) else ""),
        });
        if (str(vs, "size").len > 0 and !b.src_map.contains(str(vs, "size"))) try b.src_map.put(a, str(vs, "size"), binds.items[binds.items.len - 1].variable);
        if (lh) |x| try binds.append(a, .{
            .key = "lineHeight",
            .variable = try b.numVar(type_col, "ds:m-type", if (str(vs, "lineHeight").len > 0) shortName(str(vs, "lineHeight")) else try std.fmt.allocPrint(a, "Line height/{d}", .{x}), x, "", &.{"line-height"}, if (str(vs, "lineHeight").len > 0) try std.fmt.allocPrint(a, "From {s}.", .{str(vs, "lineHeight")}) else ""),
        });
        if (lh != null and str(vs, "lineHeight").len > 0 and !b.src_map.contains(str(vs, "lineHeight"))) try b.src_map.put(a, str(vs, "lineHeight"), binds.items[binds.items.len - 1].variable);
        var ts: m.TextStyle = .{
            .family = family,
            .weight = weight,
            .font_style = fs,
            .size = size,
            .line_height = if (lh) |x| .{
                .px = x,
            } else .auto,
            .letter_spacing = .{
                .px = ls,
            },
            .vars = binds.items,
        };
        if (std.mem.eql(u8, tt, "uppercase")) ts.case = .upper;
        const sid = try b.style(.text, try std.fmt.allocPrint(a, "Type/{s}", .{str(e, "label")}), evidenceLine(a, e), .{
            .text = ts,
        });
        var spec = b.list();
        try spec.append(a, b.strong(str(e, "label")));
        try spec.append(a, b.label(try std.fmt.allocPrint(a, "{s} {d}", .{ family, weight })));
        try spec.append(a, b.label(try std.fmt.allocPrint(a, "{d} / {s} · {d}{s}", .{ size, if (lh) |x| try std.fmt.allocPrint(a, "{d}", .{x}) else "auto", ls, if (tt.len > 0) try std.fmt.allocPrint(a, " · {s}", .{tt}) else "" })));
        var ev = b.text(evidenceLine(a, e), chrome_font, "Regular", 400, 11, 15, muted);
        ev.text.?.resize = .height;
        ev.size = .{
            .x = 260,
            .y = 15,
        };
        try spec.append(a, ev);
        var left = b.frame("spec", .vertical, 4, 0, spec.items);
        left.layout.?.width = .fixed;
        left.size = .{
            .x = 280,
            .y = 10,
        };
        var spec_text = b.text(sample, family, fs, weight, size, lh, ink);
        spec_text.text.?.style = ts;
        spec_text.text.?.resize = .height;
        spec_text.size = .{
            .x = 980,
            .y = size,
        };
        spec_text.styles.text = sid;
        var kids = b.list();
        try kids.append(a, left);
        try kids.append(a, spec_text);
        try rows.append(a, b.frame(str(e, "label"), .horizontal, 40, 0, kids.items));
        // Publr's type scale: kept in the system data; size, line height and tracking
        // as literal lengths.
    }
    var rest = b.list();
    try rest.append(a, b.text("Fonts", chrome_font, "Semi Bold", 600, 22, 28, ink));
    try rest.append(a, b.wrapRow("Fonts", 1300, 48, font_cards.items));
    try rest.append(a, b.text("Type scale", chrome_font, "Semi Bold", 600, 22, 28, ink));
    try rest.append(a, b.frame("Type scale", .vertical, 28, 0, rows.items));
    return card(b, "Typography", try titled(b, "Typography", str(obj(plan, "notes"), "typography"), rest.items));
}

fn scaleSection(b: *Builder, plan: Value, key: []const u8, title: []const u8, tokens: *std.ArrayList([2][]const u8)) !?m.Node {
    const items = arr(plan, key);
    if (items.len == 0) return null;
    const a = b.a;
    const accent = parseHex(if (str(plan, "accent").len > 0) str(plan, "accent") else "#3858e9");
    var rows = b.list();
    const radii = std.mem.eql(u8, key, "radii");
    const col_id = try std.fmt.allocPrint(a, "ds:c-{s}", .{key});
    const mode_id = try std.fmt.allocPrint(a, "ds:m-{s}", .{key});
    try b.collection(col_id, if (str(obj(plan, "collections"), key).len > 0) str(obj(plan, "collections"), key) else title, &.{.{ mode_id, "Value" }});
    for (items) |it| {
        const v = num(it, "value") orelse 0;
        try tokens.append(a, .{ str(it, "token"), try std.fmt.allocPrint(a, "{d}px", .{v}) });
        const vname = if (str(it, "variable").len > 0) shortName(str(it, "variable")) else if (str(it, "name").len > 0) str(it, "name") else str(it, "token");
        const vid = try b.numVar(col_id, mode_id, vname, v, str(it, "token"), if (radii) &.{"corner-radius"} else &.{ "gap", "width-height" }, try varNote(a, it));
        try b.mapSource(it, vid);
        var kids = b.list();
        if (radii) {
            var r = b.rect(str(it, "token"), 112, 112, line, v);
            r.strokes = b.solid(muted);
            r.stroke.weight = 1;
            // A pill's 9999 drawn at its limit (half the sample) is still bound.
            r.vars = try b.bind("radius", vid);
            try kids.append(a, r);
        } else {
            var l = b.frame("label", .vertical, 2, 0, b.list().items);
            l.layout.?.width = .fixed;
            l.size = .{
                .x = 220,
                .y = 10,
            };
            var lk = b.list();
            try lk.append(a, b.strong(str(it, "token")));
            l.children = lk.items;
            try kids.append(a, l);
            var bar = b.rect(str(it, "token"), @max(v, 1), 24, accent, 0);
            if (v >= 1) bar.vars = try b.bind("width", vid);
            try kids.append(a, bar);
        }
        var lab = b.list();
        if (radii) try lab.append(a, b.strong(str(it, "token")));
        try lab.append(a, b.label(try std.fmt.allocPrint(a, "{d}px{s}{s}", .{ v, if (str(it, "name").len > 0) " · " else "", str(it, "name") })));
        if (str(it, "variable").len > 0) try lab.append(a, b.text(try std.fmt.allocPrint(a, "← {s}", .{str(it, "variable")}), chrome_font, "Regular", 400, 11, 15, muted));
        var ev = b.text(evidenceLine(a, it), chrome_font, "Regular", 400, 11, 15, muted);
        ev.text.?.resize = .height;
        ev.size = .{
            .x = if (radii) 200 else 600,
            .y = 15,
        };
        try lab.append(a, ev);
        try kids.append(a, b.frame("about", .vertical, 2, 0, lab.items));
        var row = b.frame(str(it, "token"), if (radii) .vertical else .horizontal, if (radii) 10 else 24, 0, kids.items);
        row.layout.?.cross = if (radii) .start else .center;
        try rows.append(a, row);
    }
    var rest = b.list();
    if (radii) try rest.append(a, b.wrapRow(title, 1300, 32, rows.items)) else try rest.append(a, b.frame(title, .vertical, 16, 0, rows.items));
    return card(b, title, try titled(b, title, str(obj(plan, "notes"), key), rest.items));
}

fn effects(b: *Builder, plan: Value, tokens: *std.ArrayList([2][]const u8)) !?m.Node {
    const items = arr(plan, "shadows");
    if (items.len == 0) return null;
    const a = b.a;
    var cards = b.list();
    for (items) |it| {
        var list: std.ArrayList(m.Effect) = .empty;
        var css: std.ArrayList(u8) = .empty;
        for (arr(it, "effects")) |e| {
            const t = str(e, "type");
            const off = arr(e, "offset");
            const ox: f32 = if (off.len == 2) @floatCast(jnum(off[0])) else 0;
            const oy: f32 = if (off.len == 2) @floatCast(jnum(off[1])) else 0;
            const kind: m.EffectKind = if (std.mem.eql(u8, t, "inner-shadow")) .inner_shadow else if (std.mem.eql(u8, t, "layer-blur")) .layer_blur else if (std.mem.eql(u8, t, "background-blur")) .background_blur else .drop_shadow;
            try list.append(a, .{
                .kind = kind,
                .color = parseHex(str(e, "color")),
                .offset = .{
                    .x = ox,
                    .y = oy,
                },
                .radius = num(e, "radius") orelse 0,
                .spread = num(e, "spread") orelse 0,
            });
            try css.print(a, "{s}{s}{d}px {d}px {d}px {d}px {s}", .{ if (css.items.len > 0) ", " else "", if (kind == .inner_shadow) "inset " else "", ox, oy, num(e, "radius") orelse 0, num(e, "spread") orelse 0, str(e, "color") });
        }
        try tokens.append(a, .{ str(it, "token"), css.items });
        const sid = try b.style(.effect, try std.fmt.allocPrint(a, "Effect/{s}", .{str(it, "name")}), evidenceLine(a, it), .{
            .effect = list.items,
        });
        var box = b.rect(str(it, "token"), 200, 120, white, 12);
        box.effects = list.items;
        box.styles.effect = sid;
        var kids = b.list();
        try kids.append(a, box);
        try kids.append(a, b.strong(str(it, "token")));
        try kids.append(a, b.label(css.items));
        var ev = b.text(evidenceLine(a, it), chrome_font, "Regular", 400, 11, 15, muted);
        ev.text.?.resize = .height;
        ev.size = .{
            .x = 220,
            .y = 15,
        };
        try kids.append(a, ev);
        var cardn = b.frame(str(it, "token"), .vertical, 10, 16, kids.items);
        cardn.fills = b.solid(.{
            .r = 0.97,
            .g = 0.97,
            .b = 0.98,
        });
        cardn.radius = .{ 16, 16, 16, 16 };
        try cards.append(a, cardn);
    }
    var rest = b.list();
    try rest.append(a, b.wrapRow("Shadows", 1300, 32, cards.items));
    return card(b, "Effects", try titled(b, "Effects", str(obj(plan, "notes"), "shadows"), rest.items));
}

fn jnum(v: Value) f64 {
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => 0,
    };
}

fn breakpoints(b: *Builder, plan: Value, tokens: *std.ArrayList([2][]const u8)) !?m.Node {
    const items = arr(plan, "breakpoints");
    if (items.len == 0) return null;
    const a = b.a;
    var rows = b.list();
    try b.collection("ds:c-breakpoints", if (str(obj(plan, "collections"), "breakpoints").len > 0) str(obj(plan, "collections"), "breakpoints") else "Breakpoints", &.{.{ "ds:m-breakpoints", "Value" }});
    for (items, 0..) |it, i| {
        const wv = num(it, "width") orelse 0;
        const key = str(it, "key");
        const device = str(it, "device");
        _ = try b.numVar("ds:c-breakpoints", "ds:m-breakpoints", if (str(it, "variable").len > 0) shortName(str(it, "variable")) else if (str(it, "label").len > 0) str(it, "label") else key, wv, if (i == 0) "publr-preview-base" else try std.fmt.allocPrint(a, "breakpoint-{s}", .{key}), &.{"width-height"}, try varNote(a, it));
        if (i == 0) {
            try tokens.append(a, .{ "publr-preview-base", try std.fmt.allocPrint(a, "{d}px", .{wv}) });
        } else {
            try tokens.append(a, .{ try std.fmt.allocPrint(a, "breakpoint-{s}", .{key}), try std.fmt.allocPrint(a, "{d}px", .{wv}) });
            try tokens.append(a, .{ try std.fmt.allocPrint(a, "publr-breakpoint-{s}-device", .{key}), device });
        }
        var kids = b.list();
        var l = b.frame("label", .vertical, 2, 0, b.list().items);
        l.layout.?.width = .fixed;
        l.size = .{
            .x = 260,
            .y = 10,
        };
        var lk = b.list();
        try lk.append(a, b.strong(try std.fmt.allocPrint(a, "{s} · {d}px · {s}", .{ if (str(it, "label").len > 0) str(it, "label") else key, wv, device })));
        try lk.append(a, b.label(if (i == 0) "publr-preview-base (below the first breakpoint)" else try std.fmt.allocPrint(a, "breakpoint-{s}", .{key})));
        var ev = b.text(evidenceLine(a, it), chrome_font, "Regular", 400, 11, 15, muted);
        ev.text.?.resize = .height;
        ev.size = .{
            .x = 250,
            .y = 15,
        };
        try lk.append(a, ev);
        l.children = lk.items;
        try kids.append(a, l);
        const dc: m.Color = if (std.mem.eql(u8, device, "mobile")) .{
            .r = 0.55,
            .g = 0.75,
            .b = 0.6,
        } else if (std.mem.eql(u8, device, "tablet")) .{
            .r = 0.55,
            .g = 0.65,
            .b = 0.85,
        } else .{
            .r = 0.5,
            .g = 0.5,
            .b = 0.75,
        };
        try kids.append(a, b.rect(key, wv / 2, 32, dc, 6));
        var row = b.frame(key, .horizontal, 24, 0, kids.items);
        row.layout.?.cross = .center;
        try rows.append(a, row);
    }
    var rest = b.list();
    try rest.append(a, b.label("Bars at half scale; colour by device (green mobile, blue tablet, violet desktop)."));
    try rest.append(a, b.frame("Breakpoints", .vertical, 20, 0, rows.items));
    return card(b, "Breakpoints", try titled(b, "Breakpoints", str(obj(plan, "notes"), "breakpoints"), rest.items));
}

// ------------------------------------------------------------------ carried over

const Carry = struct {
    b: *Builder,
    gpa: A,
    /// Source glyph index to ours, per source page build (indices are the source's).
    remap: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    copied: u32 = 0,
    missing: u32 = 0,
    src: ?*Source = null,
    /// Source variable reference to ours (null: not a token here), memoized.
    refs: std.StringHashMapUnmanaged(?[]const u8) = .empty,
    /// Source `collection\x00mode` to ours, for modes carried-over nodes set.
    modes: std.StringHashMapUnmanaged(m.ModeChoice) = .empty,
    rebound: u32 = 0,
    dropped: u32 = 0,

    fn deinit(c: *Carry) void {
        c.remap.deinit(c.gpa);
    }

    /// Our variable for a source reference: the source variable's own mapping, else that
    /// of a variable it aliases (in any mode, to any depth).
    fn ref(c: *Carry, r: []const u8) !?[]const u8 {
        if (c.refs.get(r)) |x| return x;
        const out = if (c.src) |s| (if (s.variable(r)) |v| try c.mapped(s, v, 0) else null) else null;
        try c.refs.put(c.b.a, try c.b.a.dupe(u8, r), out);
        if (out != null) c.rebound += 1 else c.dropped += 1;
        return out;
    }

    fn mapped(c: *Carry, s: *Source, v: *const m.Variable, depth: u32) !?[]const u8 {
        const col = s.collection(v.collection);
        const full = try std.fmt.allocPrint(c.b.a, "{s}/{s}", .{ if (col) |x| x.name else "?", v.name });
        if (c.b.src_map.get(full)) |id| return id;
        if (depth > 16) return null;
        for (v.values) |val| {
            var rest = val.value;
            const tag = "\"alias\":\"";
            while (std.mem.indexOf(u8, rest, tag)) |i| {
                const t = rest[i + tag.len ..];
                const e = std.mem.indexOfScalar(u8, t, '"') orelse break;
                if (s.variable(t[0..e])) |nv| if (try c.mapped(s, nv, depth + 1)) |id| return id;
                rest = t[e..];
            }
        }
        return null;
    }

    fn bindings(c: *Carry, list: []m.VarBinding) ![]m.VarBinding {
        var out: std.ArrayList(m.VarBinding) = .empty;
        for (list) |x| if (try c.ref(x.variable)) |id| try out.append(c.b.a, .{
            .key = x.key,
            .variable = id,
        });
        return out.items;
    }

    fn paints(c: *Carry, ps: []m.Paint) !void {
        for (ps) |*p| {
            if (p.variable) |v| p.variable = try c.ref(v);
            p.vars = try c.bindings(p.vars);
            for (p.stops) |*st| if (st.variable) |v| {
                st.variable = try c.ref(v);
            };
        }
    }

    /// A copy of `n` for this file: instances lose `component` (their main is not
    /// here), images are left out, glyphs renumbered into ours.
    fn copy(c: *Carry, n: *const m.Node, glyphs: []const []const u8) !m.Node {
        const a = c.b.a;
        var out = try m.deepCopy(a, n.*);
        try c.fix(&out, glyphs);
        out.absolute = false;
        out.sizing = null;
        out.constraints = .{};
        out.visible = true;
        return out;
    }

    fn fix(c: *Carry, n: *m.Node, glyphs: []const []const u8) !void {
        const a = c.b.a;
        if (n.kind == .instance) n.component = null;
        n.styles = .{};
        n.fills = try dropImages(a, n.fills);
        n.strokes = try dropImages(a, n.strokes);
        // Bindings to source variables the system maps go to its variables; the rest go.
        n.vars = try c.bindings(n.vars);
        try c.paints(n.fills);
        try c.paints(n.strokes);
        for (n.effects) |*e| e.vars = try c.bindings(e.vars);
        for (n.grids) |*g| g.vars = try c.bindings(g.vars);
        var ms: std.ArrayList(m.ModeChoice) = .empty;
        for (n.modes) |mc| {
            const key = try std.fmt.allocPrint(a, "{s}\x00{s}", .{ mc.collection, mc.mode });
            if (c.modes.get(key)) |ours| try ms.append(a, ours);
        }
        n.modes = ms.items;
        if (n.text) |*t| {
            t.style.vars = try c.bindings(t.style.vars);
            for (t.runs) |*r| {
                r.style.vars = try c.bindings(r.style.vars);
                if (r.fills) |fs| try c.paints(fs);
            }
            for (t.glyphs) |*g| {
                const gop = try c.remap.getOrPut(c.gpa, g.outline);
                if (!gop.found_existing) {
                    gop.value_ptr.* = @intCast(c.b.glyphs.items.len);
                    try c.b.glyphs.append(a, if (g.outline < glyphs.len) try a.dupe(u8, glyphs[g.outline]) else "");
                }
                g.outline = gop.value_ptr.*;
            }
            for (t.runs) |*r| if (r.fills) |fs| {
                r.fills = try dropImages(a, fs);
            };
        }
        for (n.children) |*ch| try c.fix(ch, glyphs);
    }
};

fn dropImages(a: A, ps: []m.Paint) ![]m.Paint {
    var out: std.ArrayList(m.Paint) = .empty;
    for (ps) |p| if (p.kind != .image and p.kind != .pattern) try out.append(a, p);
    return out.items;
}

fn findIn(n: *const m.Node, id: []const u8) ?*const m.Node {
    if (std.mem.eql(u8, n.id, id)) return n;
    for (n.children) |*c| if (findIn(c, id)) |f| return f;
    return null;
}

fn carried(b: *Builder, carry: *Carry, src: *Source, plan: Value, key: []const u8, title: []const u8) !?m.Node {
    const items = arr(plan, key);
    if (items.len == 0) return null;
    const a = b.a;
    const icons = std.mem.eql(u8, key, "icons");
    // Grouped by page so each source page is built once.
    var tiles = b.list();
    const order = try a.alloc(usize, items.len);
    for (order, 0..) |*o, i| o.* = i;
    std.mem.sort(usize, order, items, struct {
        fn less(v: []Value, x: usize, y: usize) bool {
            return jnum(obj(v[x], "page")) < jnum(obj(v[y], "page"));
        }
    }.less);
    var built: std.AutoHashMapUnmanaged(usize, m.Node) = .empty;
    var scratch: std.heap.ArenaAllocator = .init(carry.gpa);
    defer scratch.deinit();
    const copies = try a.alloc(?m.Node, items.len);
    var current: ?usize = null;
    var page: m.Node = undefined;
    for (order) |i| {
        const it = items[i];
        const pi: usize = @intFromFloat(jnum(obj(it, "page")));
        if (current == null or current.? != pi) {
            _ = scratch.reset(.retain_capacity);
            carry.remap.clearRetainingCapacity();
            page = try src.page(scratch.allocator(), pi);
            current = pi;
        }
        const found = findIn(&page, str(it, "source"));
        if (found) |n| {
            copies[i] = try carry.copy(n, if (src.im) |im| im.glyphs() else src.glyphs);
            carry.copied += 1;
        } else {
            copies[i] = null;
            carry.missing += 1;
        }
    }
    _ = &built;
    for (items, copies) |it, cp| {
        var kids = b.list();
        if (cp) |n| {
            var node = n;
            node.transform = .identity;
            if (icons) {
                var holder = b.frame("icon", .horizontal, 0, 0, b.list().items);
                holder.layout.?.main = .center;
                holder.layout.?.cross = .center;
                holder.layout.?.width = .fixed;
                holder.layout.?.height = .fixed;
                holder.size = .{
                    .x = @max(72, node.size.x + 16),
                    .y = @max(72, node.size.y + 16),
                };
                holder.fills = b.solid(.{
                    .r = 0.97,
                    .g = 0.97,
                    .b = 0.98,
                });
                holder.radius = .{ 12, 12, 12, 12 };
                var hk = b.list();
                try hk.append(a, node);
                holder.children = hk.items;
                try kids.append(a, holder);
            } else try kids.append(a, node);
        } else try kids.append(a, b.label(try std.fmt.allocPrint(a, "(not found in the source: {s})", .{str(it, "source")})));
        try kids.append(a, b.strong(str(it, "name")));
        var ev = b.text(try std.fmt.allocPrint(a, "{s}{s}{s}", .{ str(it, "note"), if (str(it, "note").len > 0) " · " else "", evidenceLine(a, it) }), chrome_font, "Regular", 400, 11, 15, muted);
        ev.text.?.resize = .height;
        ev.size = .{
            .x = if (icons) 110 else 600,
            .y = 15,
        };
        try kids.append(a, ev);
        try tiles.append(a, b.frame(str(it, "name"), .vertical, 8, 0, kids.items));
    }
    var rest = b.list();
    if (icons) try rest.append(a, b.wrapRow(title, 1300, 20, tiles.items)) else try rest.append(a, b.frame(title, .vertical, 40, 0, tiles.items));
    return card(b, title, try titled(b, title, str(obj(plan, "notes"), key), rest.items));
}

// ------------------------------------------------------------------ Publr's shape

/// The system in Publr's design system builder shape (`editor/design/model/system.ts`):
/// tokens in the jit's naming, fonts, colour roles, the type scale, icons by name.
fn systemData(a: A, plan: Value, tokens: []const [2][]const u8) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(a);
    var s: std.json.Stringify = .{
        .writer = &aw.writer,
    };
    try s.beginObject();
    try s.objectField("publr");
    try s.beginObject();
    try s.objectField("designSystem");
    try s.beginObject();
    try s.objectField("tokens");
    try s.beginArray();
    for (tokens) |t| {
        try s.beginObject();
        try s.objectField("name");
        try s.write(t[0]);
        try s.objectField("value");
        try s.write(t[1]);
        try s.endObject();
    }
    try s.endArray();
    try s.objectField("fonts");
    try s.beginArray();
    for (arr(plan, "fonts")) |f| {
        try s.beginObject();
        try s.objectField("token");
        try s.write(str(f, "token"));
        try s.objectField("family");
        try s.write(str(f, "family"));
        try s.objectField("fallback");
        try s.write(if (str(f, "fallback").len > 0) str(f, "fallback") else "sans-serif");
        try s.objectField("provider");
        try s.write("files");
        try s.objectField("faces");
        try s.beginArray();
        try s.endArray();
        try s.endObject();
    }
    try s.endArray();
    try s.objectField("roles");
    try s.beginArray();
    for (arr(obj(plan, "colors"), "roles")) |r| {
        try s.beginObject();
        try s.objectField("key");
        try s.write(str(r, "role"));
        try s.objectField("label");
        try s.write(str(r, "label"));
        try s.objectField("description");
        try s.write(str(r, "reason"));
        try s.objectField("value");
        var hex = str(r, "value");
        for (arr(obj(plan, "colors"), "palette")) |p| if (std.mem.eql(u8, str(p, "token"), str(r, "palette"))) {
            hex = str(p, "value");
        };
        try s.write(hex);
        try s.endObject();
    }
    try s.endArray();
    try s.objectField("contexts");
    try s.beginArray();
    for (try contextsOf(a, plan)) |cx| {
        try s.beginObject();
        try s.objectField("key");
        try s.write(cx[0]);
        try s.objectField("label");
        try s.write(cx[1]);
        try s.endObject();
    }
    try s.endArray();
    try s.objectField("typeScale");
    try s.beginArray();
    for (arr(plan, "typeScale")) |e| {
        try s.beginObject();
        try s.objectField("key");
        try s.write(str(e, "key"));
        try s.objectField("label");
        try s.write(str(e, "label"));
        try s.objectField("fontRole");
        try s.write(str(e, "fontRole"));
        try s.objectField("weight");
        try s.write(num(e, "weight") orelse 400);
        try s.objectField("size");
        try s.write(try std.fmt.allocPrint(a, "{d}px", .{num(e, "size") orelse 16}));
        try s.objectField("lineHeight");
        try s.write(if (num(e, "lineHeight")) |x| try std.fmt.allocPrint(a, "{d}px", .{x}) else "");
        try s.objectField("letterSpacing");
        try s.write(if (num(e, "letterSpacing")) |x| try std.fmt.allocPrint(a, "{d}px", .{x}) else "");
        try s.objectField("textTransform");
        try s.write(str(e, "textTransform"));
        try s.objectField("description");
        try s.write(str(e, "reason"));
        try s.endObject();
    }
    try s.endArray();
    try s.objectField("icons");
    try s.beginArray();
    for (arr(plan, "icons")) |i| try s.write(str(i, "name"));
    try s.endArray();
    try s.objectField("managedColorTokens");
    try s.beginArray();
    try s.endArray();
    try s.objectField("blockDefaults");
    try s.beginObject();
    try s.endObject();
    try s.endObject();
    try s.endObject();
    try s.endObject();
    return aw.written();
}
