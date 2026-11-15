//! Model inference, measured (experimental research tool).
//!
//! Reads a `.pubd` folder through the engine's Pubd reader and infers the Publr editing
//! model the design states: blocks, fields, open areas, lists, validations and locked
//! regions. Every decision records the rule that made it, a confidence, and who settles
//! it: `certain` (applied silently), `agent` (the agent decides from names, structure or
//! visuals, shown as inferred) or `person` (a question in the queue).
//!
//! It runs twice per file: `strict` uses only the rules written in the spec (Model mode),
//! `smart` adds the rules this measurement proposes (drawn sections, geometric stacks,
//! look-alike lists, detached copies, breakpoints, copies as entries).
//!
//!   model-inference <label> <doc.pubd-dir> <out.json>

const std = @import("std");
const engine = @import("publr_engine");

const m = engine.model;
const Node = m.Node;
const Io = std.Io;
const Dir = std.Io.Dir;
const A = std.mem.Allocator;

const max_file = 512 * 1024 * 1024;

const Mode = enum {
    strict,
    smart,
};

const Resolver = enum {
    certain,
    agent,
    person,
};

const Kind = enum {
    page_role,
    template,
    template_copy,
    fragment,
    block,
    block_merge,
    field,
    open_area,
    allowed_set,
    list,
    validation,
    locked,
    hidden,
    nested_property,
};

const Decision = struct {
    page: []const u8 = "",
    kind: Kind,
    detail: []const u8,
    where: []const u8,
    rule: []const u8,
    confidence: f32,
    resolver: Resolver,
    question: ?[]const u8 = null,
    wording: ?[]const u8 = null,
    default: ?[]const u8 = null,
};

/// Site-level defaults: one answer that settles a whole class of questions.
const Default = struct {
    id: []const u8,
    wording: []const u8,
};

const defaults = [_]Default{
    .{
        .id = "drawn-sections",
        .wording = "Sections drawn without a component: make their text and images editable, keep their layout fixed?",
    },
    .{
        .id = "page-stacks",
        .wording = "Pages built as a stack of full-width sections: let editors add, reorder and remove sections?",
    },
    .{
        .id = "swap-sets",
        .wording = "Where a design lets a nested component be swapped but names no preferred ones: offer the other components of the same set?",
    },
    .{
        .id = "data-product",
        .wording = "Frames named for a product (PDP, product): are the name, price, photos and options the product's own fields from Products, not page content?",
    },
    .{
        .id = "data-cart",
        .wording = "Cart and minicart frames: are they the shop's cart, filled from the visitor's cart, with only their headings and notes editable?",
    },
    .{
        .id = "data-listing",
        .wording = "Collection, category and listing frames: do their product cards come from a query over Products, with only the headings editable?",
    },
    .{
        .id = "data-post",
        .wording = "Frames named for a post or article: are the title, date, author and body the post's own fields?",
    },
    .{
        .id = "style-highlight",
        .wording = "Words coloured or sized differently inside one text: offer that look to editors as a Highlight format?",
    },
};

const Source = enum {
    component,
    library,
    drawn,
    fixed,
};

const Block = struct {
    key: []const u8,
    name: []const u8,
    source: Source,
    sig: u64,
    fields: u32 = 0,
    texts: u32 = 0,
    images: u32 = 0,
    uses: u32 = 0,
    where: []const u8,
    merged_into: ?[]const u8 = null,
    /// Every word the block shows, lower-cased (for matching breakpoints).
    words: []const []const u8 = &.{},
    /// Structure with repeats collapsed (for look-alikes that differ only in list length).
    loose: u64 = 0,
};

const Template = struct {
    page: []const u8,
    name: []const u8,
    group: []const u8,
    breakpoint: []const u8,
    width: f32,
    height: f32,
    stack: []const u8,
    stack_layer: []const u8,
    sections: u32 = 0,
    section_blocks: u32 = 0,
    drawn_sections: u32 = 0,
    outside_blocks: u32 = 0,
    locked: u32 = 0,
    open_area: bool = false,
    allowed: []const []const u8 = &.{},
    seq: u64 = 0,
};

const Coverage = struct {
    texts: u32 = 0,
    texts_editable: u32 = 0,
    images: u32 = 0,
    images_editable: u32 = 0,
};

const Names = struct {
    property: u32 = 0,
    layer: u32 = 0,
    none: u32 = 0,
};

const PageInfo = struct {
    name: []const u8,
    role: []const u8,
    templates: u32 = 0,
    fragments: u32 = 0,
    components: u32 = 0,
    loose: u32 = 0,
    certain: u32 = 0,
    agent: u32 = 0,
    person: u32 = 0,
};

const Ctx = struct {
    a: A,
    mode: Mode,
    nodes: std.StringHashMapUnmanaged(*const Node) = .empty,
    set_of: std.StringHashMapUnmanaged(*const Node) = .empty,
    comp_by_sig: std.AutoHashMapUnmanaged(u64, *const Node) = .empty,
    blocks: std.StringArrayHashMapUnmanaged(Block) = .empty,
    drawn: std.AutoHashMapUnmanaged(u64, []const u8) = .empty,
    decisions: std.ArrayList(Decision) = .empty,
    templates: std.ArrayList(Template) = .empty,
    pages: std.ArrayList(PageInfo) = .empty,
    page: []const u8 = "",
    cov: Coverage = .{},
    names: Names = .{},

    fn add(c: *Ctx, d: Decision) !void {
        var x = d;
        x.page = c.page;
        try c.decisions.append(c.a, x);
    }

    fn smart(c: *const Ctx) bool {
        return c.mode == .smart;
    }
};

// ---------------------------------------------------------------------------------------
// Reading the design

fn index(c: *Ctx, n: *const Node) !void {
    try c.nodes.put(c.a, n.id, n);
    for (n.children) |*ch| {
        if (n.kind == .component_set and ch.kind == .component) try c.set_of.put(c.a, ch.id, n);
        try index(c, ch);
    }
}

fn isImage(n: *const Node) bool {
    if (n.kind == .text) return false;
    for (n.fills) |p| if (p.visible and p.kind == .image) return true;
    return false;
}

fn hasContent(n: *const Node) bool {
    if (!n.visible) return false;
    if (n.kind == .text or isImage(n)) return true;
    for (n.children) |*ch| if (hasContent(ch)) return true;
    return false;
}

fn isBox(k: m.Kind) bool {
    return switch (k) {
        .frame, .component, .component_set, .instance => true,
        else => false,
    };
}

/// A structural fingerprint: kinds and child counts, not text or names, so two copies of
/// one section with different words match.
fn sigInto(h: *std.hash.Wyhash, n: *const Node, depth: u32) void {
    h.update(if (isBox(n.kind)) "box" else @tagName(n.kind));
    if (isImage(n)) h.update("img");
    if (n.kind == .text or depth == 0) return;
    var count: u8 = 0;
    for (n.children) |*ch| {
        if (ch.visible) count +%= 1;
    }
    h.update(&.{count});
    for (n.children) |*ch| {
        if (!ch.visible) continue;
        h.update("(");
        sigInto(h, ch, depth - 1);
        h.update(")");
    }
}

/// `sigInto` that ignores how many times a child repeats in a row: a row of three cards
/// and a row of four match.
fn looseInto(h: *std.hash.Wyhash, n: *const Node, depth: u32) void {
    h.update(if (isBox(n.kind)) "box" else @tagName(n.kind));
    if (isImage(n)) h.update("img");
    if (n.kind == .text or depth == 0) return;
    var last: u64 = 0;
    for (n.children) |*ch| {
        if (!ch.visible) continue;
        var sub = std.hash.Wyhash.init(0);
        looseInto(&sub, ch, depth - 1);
        const v = sub.final();
        if (v == last) continue;
        last = v;
        h.update("(");
        h.update(std.mem.asBytes(&v));
        h.update(")");
    }
}

fn looseSig(n: *const Node) u64 {
    var h = std.hash.Wyhash.init(0);
    looseInto(&h, n, 4);
    return h.final();
}

fn sig(n: *const Node, depth: u32, with_size: bool) u64 {
    var h = std.hash.Wyhash.init(0);
    if (with_size) {
        const w: i32 = @intFromFloat(@round(n.size.x / 16));
        const hh: i32 = @intFromFloat(@round(n.size.y / 16));
        h.update(std.mem.asBytes(&w));
        h.update(std.mem.asBytes(&hh));
    }
    sigInto(&h, n, depth);
    return h.final();
}

const generic_prefixes = [_][]const u8{
    "Frame",     "Group", "Rectangle", "Vector",  "Ellipse",     "Mask group", "Image",
    "Line",      "Union", "Subtract",  "Polygon", "Star",        "Layer",      "Text",
    "Container", "Shape", "Path",      "image",   "Auto Layout", "Component",  "Instance",
    "Variant",   "Copy",
};

/// A layer name Figma made up (`Frame 9987`, `Rectangle 899`): no hint in it.
fn isGenericName(name: []const u8) bool {
    const t = std.mem.trim(u8, name, " ");
    if (t.len == 0) return true;
    for (generic_prefixes) |p| {
        if (!std.ascii.startsWithIgnoreCase(t, p)) continue;
        const rest = std.mem.trim(u8, t[p.len..], " ");
        var all_digits = true;
        for (rest) |ch| {
            if (!std.ascii.isDigit(ch)) all_digits = false;
        }
        if (all_digits) return true;
    }
    return false;
}

/// A text layer named after its own words (Figma's default) carries no hint.
fn textNameIsDefault(n: *const Node) bool {
    const t = n.text orelse return true;
    const name = std.mem.trim(u8, n.name, " ");
    if (name.len == 0) return true;
    const body = std.mem.trim(u8, t.text, " \n");
    if (std.mem.startsWith(u8, body, name)) return true;
    if (std.mem.startsWith(u8, name, body[0..@min(body.len, name.len)]) and body.len > 0) return true;
    return isGenericName(name);
}

fn lower(a: A, s: []const u8) ![]u8 {
    const out = try a.alloc(u8, s.len);
    for (s, 0..) |ch, i| out[i] = std.ascii.toLower(ch);
    return out;
}

const breakpoint_words = [_][]const u8{ "desktop", "mobile", "tablet", "phone", "web" };

/// The name without breakpoint words, numbers and punctuation: "Homepage - Desktop - 1280"
/// and "Homepage - Mobile - 376" are both "homepage".
fn normName(a: A, name: []const u8) ![]const u8 {
    const l = try lower(a, name);
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.tokenizeAny(u8, l, " -_()/.,:;|→>");
    while (it.next()) |word| {
        var skip = false;
        for (breakpoint_words) |bw| {
            if (std.mem.eql(u8, word, bw)) skip = true;
        }
        var digits = true;
        for (word) |ch| {
            if (!std.ascii.isDigit(ch)) digits = false;
        }
        if (skip or digits) continue;
        if (out.items.len > 0) try out.append(a, ' ');
        try out.appendSlice(a, word);
    }
    return out.items;
}

fn breakpointWord(name: []const u8) ?[]const u8 {
    for (breakpoint_words) |bw| {
        if (std.ascii.findIgnoreCase(name, bw) != null) return bw;
    }
    return null;
}

fn breakpointOf(w: f32) []const u8 {
    if (w < 600) return "mobile";
    if (w < 1100) return "tablet";
    return "desktop";
}

fn path(a: A, parent: []const u8, name: []const u8) ![]const u8 {
    const shown = if (name.len > 60) name[0..60] else name;
    if (parent.len == 0) return a.dupe(u8, shown);
    return std.fmt.allocPrint(a, "{s} / {s}", .{ parent, shown });
}

fn short(s: []const u8) []const u8 {
    const t = std.mem.trim(u8, s, " \n");
    var end: usize = @min(t.len, 48);
    while (end < t.len and end > 0 and (t[end] & 0xC0) == 0x80) end -= 1;
    if (std.mem.indexOfScalar(u8, t[0..end], '\n')) |nl| end = nl;
    return t[0..end];
}

const DataKind = struct {
    id: []const u8,
    label: []const u8,
};

/// Template names that say the page shows records (a product, a cart), not free content.
fn dataKind(name: []const u8) ?DataKind {
    const table = [_]struct {
        word: []const u8,
        kind: DataKind,
    }{
        .{
            .word = "pdp",
            .kind = .{
                .id = "data-product",
                .label = "product",
            },
        },
        .{
            .word = "product",
            .kind = .{
                .id = "data-product",
                .label = "product",
            },
        },
        .{
            .word = "cart",
            .kind = .{
                .id = "data-cart",
                .label = "cart",
            },
        },
        .{
            .word = "checkout",
            .kind = .{
                .id = "data-cart",
                .label = "cart",
            },
        },
        .{
            .word = "collection",
            .kind = .{
                .id = "data-listing",
                .label = "product listing",
            },
        },
        .{
            .word = "category",
            .kind = .{
                .id = "data-listing",
                .label = "product listing",
            },
        },
        .{
            .word = "plp",
            .kind = .{
                .id = "data-listing",
                .label = "product listing",
            },
        },
        .{
            .word = "blog",
            .kind = .{
                .id = "data-post",
                .label = "post",
            },
        },
        .{
            .word = "article",
            .kind = .{
                .id = "data-post",
                .label = "post",
            },
        },
    };
    for (table) |e| {
        if (std.ascii.findIgnoreCase(name, e.word) != null) return e.kind;
    }
    return null;
}

fn isButtonName(name: []const u8) bool {
    const words = [_][]const u8{ "button", "btn", "cta", "link" };
    for (words) |w| {
        if (std.ascii.findIgnoreCase(name, w) != null) return true;
    }
    return false;
}

fn isSharedPartName(name: []const u8) bool {
    const words = [_][]const u8{ "nav", "header", "footer", "menu" };
    for (words) |w| {
        if (std.ascii.findIgnoreCase(name, w) != null) return true;
    }
    return false;
}

/// Property ids look like `2120:1`; a variant property's id is its name.
fn isIdLike(id: []const u8) bool {
    if (id.len == 0) return false;
    for (id) |ch| {
        if (!(std.ascii.isDigit(ch) or ch == ':' or ch == '#' or ch == ';')) return false;
    }
    return true;
}

fn isGenericVariant(s: []const u8) bool {
    const t = std.mem.trim(u8, s, " \"");
    if (std.ascii.startsWithIgnoreCase(t, "Property")) return true;
    if (std.ascii.startsWithIgnoreCase(t, "Variant")) return true;
    if (std.ascii.eqlIgnoreCase(t, "Default")) return true;
    return false;
}

// ---------------------------------------------------------------------------------------
// Text

const TextInfo = struct {
    kind: []const u8,
    /// Style changes that are not a usual format (colour, size, font, case).
    odd: []const u8 = "",
};

fn firstSolid(fills: []const m.Paint) ?m.Color {
    for (fills) |p| if (p.visible and p.kind == .solid) return p.color;
    return null;
}

fn sameColour(x: ?m.Color, y: ?m.Color) bool {
    const p = x orelse return y == null;
    const q = y orelse return false;
    return @abs(p.r - q.r) < 0.01 and @abs(p.g - q.g) < 0.01 and @abs(p.b - q.b) < 0.01 and @abs(p.a - q.a) < 0.01;
}

fn utf16Len(s: []const u8) u32 {
    var n: u32 = 0;
    for (s) |b| {
        if ((b & 0xC0) != 0x80) n += 1;
        if (b >= 0xF0) n += 1;
    }
    return n;
}

fn textInfo(a: A, n: *const Node) !TextInfo {
    const t = n.text orelse return .{
        .kind = "text",
    };
    const base = t.style;
    var bold = false;
    var italic = false;
    var deco = false;
    var size = false;
    var family = false;
    var case_ = false;
    var colour = false;
    const len = utf16Len(t.text);
    for (t.runs) |r| {
        if (r.from == 0 and r.to >= len and t.runs.len == 1) continue;
        if (r.style.weight) |w| if (w != (base.weight orelse 400)) {
            bold = true;
        };
        if (r.style.italic) |i| if (i != (base.italic orelse false)) {
            italic = true;
        };
        if (r.style.decoration) |d| if (d != (base.decoration orelse .none)) {
            deco = true;
        };
        if (r.style.size) |s| if (@abs(s - (base.size orelse 16)) > 0.5) {
            size = true;
        };
        if (r.style.family) |f| if (base.family == null or !std.mem.eql(u8, f, base.family.?)) {
            family = true;
        };
        if (r.style.case) |cs| if (cs != (base.case orelse .none)) {
            case_ = true;
        };
        if (r.fills) |fs| if (!sameColour(firstSolid(fs), firstSolid(n.fills))) {
            colour = true;
        };
    }
    var odd: std.ArrayList(u8) = .empty;
    const odd_parts = [_]struct {
        on: bool,
        name: []const u8,
    }{
        .{
            .on = colour,
            .name = "colour",
        },
        .{
            .on = size,
            .name = "size",
        },
        .{
            .on = family,
            .name = "font",
        },
        .{
            .on = case_,
            .name = "case",
        },
    };
    for (odd_parts) |p| {
        if (!p.on) continue;
        if (odd.items.len > 0) try odd.appendSlice(a, ", ");
        try odd.appendSlice(a, p.name);
    }
    if (bold or italic or deco or odd.items.len > 0) return .{
        .kind = "rich text",
        .odd = odd.items,
    };
    if (std.mem.indexOfScalar(u8, t.text, '\n') != null or std.mem.indexOf(u8, t.text, "\u{2028}") != null) return .{
        .kind = "multi-line",
    };
    return .{
        .kind = "text",
    };
}

// ---------------------------------------------------------------------------------------
// Blocks and their fields

const Scope = struct {
    block: []const u8,
    where: []const u8,
    /// The properties the nearest instance (or the block's own main) offers.
    props: []const m.PropDef = &.{},
    /// The nearest owner of `bind`s is the block itself (not a nested instance).
    owner_root: bool = true,
    optional: bool = false,
    in_drawn: bool = false,
    /// Strict mode on a drawn region: only what sits inside an instance is content.
    need_instance: bool = false,
    inside_instance: bool = false,
};

fn mainProps(c: *Ctx, inst: *const Node) ![]const m.PropDef {
    const id = inst.component orelse return &.{};
    const mc = c.nodes.get(id) orelse return &.{};
    const set = c.set_of.get(mc.id);
    var out: std.ArrayList(m.PropDef) = .empty;
    if (set) |s| try out.appendSlice(c.a, s.properties);
    try out.appendSlice(c.a, mc.properties);
    return out.items;
}

fn findProp(props: []const m.PropDef, id: []const u8) ?m.PropDef {
    for (props) |p| if (std.mem.eql(u8, p.id, id)) return p;
    return null;
}

fn bumpBlock(c: *Ctx, key: []const u8, comptime f: []const u8) void {
    if (c.blocks.getPtr(key)) |b| @field(b, f) += 1;
}

fn contentAllowed(s: Scope) bool {
    return !s.need_instance or s.inside_instance;
}

fn textField(c: *Ctx, s: Scope, n: *const Node) !void {
    if (!contentAllowed(s)) return;
    const ti = try textInfo(c.a, n);
    const own = s.owner_root and n.bind.text != null;
    const where = try path(c.a, s.where, n.name);
    const rule: []const u8 = if (own)
        "a text property of the block → a typed text field"
    else if (n.bind.text != null)
        "a text property of a nested instance → content"
    else if (s.in_drawn)
        "text in a drawn section → content (drawn-sections default)"
    else
        "text inside an instance → content";
    try c.add(.{
        .kind = .field,
        .detail = ti.kind,
        .where = where,
        .rule = rule,
        .confidence = if (s.in_drawn) 0.85 else 0.95,
        .resolver = .certain,
    });
    bumpBlock(c, s.block, "fields");
    bumpBlock(c, s.block, "texts");
    if (own) {
        c.names.property += 1;
    } else if (!textNameIsDefault(n)) {
        c.names.layer += 1;
    } else {
        c.names.none += 1;
    }
    if (ti.odd.len > 0) try c.add(.{
        .kind = .field,
        .detail = "format",
        .where = where,
        .rule = "styles mixed inside one text that are not bold, italic or underline",
        .confidence = 0.5,
        .resolver = .person,
        .question = "style-format",
        .wording = try std.fmt.allocPrint(c.a, "“{s}” mixes {s} inside one text. Offer that look to editors as a format, or keep one style?", .{ short((n.text orelse m.Text{}).text), ti.odd }),
        .default = "style-highlight",
    });
    try c.add(.{
        .kind = .validation,
        .detail = if (s.optional) "optional" else "required",
        .where = where,
        .rule = if (s.optional) "hidden by a boolean property → optional" else "always present in the design → required",
        .confidence = 0.9,
        .resolver = .certain,
    });
    const t = n.text orelse return;
    if (t.resize == .fixed or t.resize == .truncate) try c.add(.{
        .kind = .validation,
        .detail = "length guide",
        .where = where,
        .rule = "a text in a fixed-size box → a length guide from what fits",
        .confidence = 0.9,
        .resolver = .certain,
    });
}

fn imageField(c: *Ctx, s: Scope, n: *const Node) !void {
    if (!contentAllowed(s)) return;
    const where = try path(c.a, s.where, n.name);
    if (@max(n.size.x, n.size.y) < 32) {
        try c.add(.{
            .kind = .locked,
            .detail = "small image (icon)",
            .where = where,
            .rule = "an image under 32 px is an icon, part of the design",
            .confidence = 0.8,
            .resolver = .agent,
        });
        return;
    }
    try c.add(.{
        .kind = .field,
        .detail = "image",
        .where = where,
        .rule = if (s.in_drawn) "image fill in a drawn section → media (drawn-sections default)" else "image fill inside an instance → media",
        .confidence = if (s.in_drawn) 0.85 else 0.95,
        .resolver = .certain,
    });
    bumpBlock(c, s.block, "fields");
    bumpBlock(c, s.block, "images");
    if (isGenericName(n.name)) {
        c.names.none += 1;
    } else {
        c.names.layer += 1;
    }
    try c.add(.{
        .kind = .validation,
        .detail = if (s.optional) "optional" else "required",
        .where = where,
        .rule = if (s.optional) "hidden by a boolean property → optional" else "always present in the design → required",
        .confidence = 0.9,
        .resolver = .certain,
    });
    try c.add(.{
        .kind = .validation,
        .detail = "crop ratio",
        .where = where,
        .rule = "the image's frame → its crop ratio",
        .confidence = 0.95,
        .resolver = .certain,
    });
    try c.add(.{
        .kind = .validation,
        .detail = "minimum size",
        .where = where,
        .rule = "the image's frame → its minimum size",
        .confidence = 0.9,
        .resolver = .certain,
    });
}

const ListPick = struct {
    key: u64,
    count: u32,
    certain: bool,
};

fn itemKey(c: *Ctx, n: *const Node, auto_layout: bool) ?u64 {
    if (!n.visible or n.absolute) return null;
    if (n.kind == .instance) {
        if (!hasContent(n)) return null;
        var h = std.hash.Wyhash.init(1);
        h.update(n.component orelse n.name);
        return h.final();
    }
    if (!c.smart()) return null;
    if (n.kind == .text) {
        if (!auto_layout) return null;
        const t = n.text orelse return null;
        var h = std.hash.Wyhash.init(2);
        h.update(t.style.family orelse "");
        const size: i32 = @intFromFloat(@round(t.style.size orelse 16));
        h.update(std.mem.asBytes(&size));
        return h.final();
    }
    if (n.children.len == 0) {
        // Images drawn as plain rectangles side by side: the same size → one kind of item.
        if (!isImage(n) or @max(n.size.x, n.size.y) < 32) return null;
        var h = std.hash.Wyhash.init(3);
        const w: i32 = @intFromFloat(@round(n.size.x / 4));
        const hh: i32 = @intFromFloat(@round(n.size.y / 4));
        h.update(std.mem.asBytes(&w));
        h.update(std.mem.asBytes(&hh));
        return h.final();
    }
    if (!hasContent(n)) return null;
    return sig(n, 3, false) ^ 0x5bd1e995;
}

fn findList(c: *Ctx, n: *const Node) ?ListPick {
    const auto_layout = n.layout != null;
    var keys: [64]u64 = undefined;
    var counts: [64]u32 = undefined;
    var inst: [64]bool = undefined;
    var texts: [64]bool = undefined;
    var len: usize = 0;
    for (n.children) |*ch| {
        const k = itemKey(c, ch, auto_layout) orelse continue;
        var found = false;
        for (keys[0..len], 0..) |kk, i| {
            if (kk == k) {
                counts[i] += 1;
                found = true;
            }
        }
        if (!found and len < keys.len) {
            keys[len] = k;
            counts[len] = 1;
            inst[len] = ch.kind == .instance;
            texts[len] = ch.kind == .text;
            len += 1;
        }
    }
    var best: ?ListPick = null;
    for (0..len) |i| {
        const need: u32 = if (auto_layout and !texts[i]) 2 else 3;
        if (counts[i] < need) continue;
        if (inst[i] and !auto_layout and !c.smart()) continue;
        const certain = inst[i] and auto_layout;
        if (best == null or counts[i] > best.?.count) best = .{
            .key = keys[i],
            .count = counts[i],
            .certain = certain,
        };
    }
    return best;
}

fn walkChildren(c: *Ctx, s: Scope, n: *const Node) anyerror!void {
    const list = findList(c, n);
    var seen_item = false;
    for (n.children) |*ch| {
        if (list) |l| {
            if (itemKey(c, ch, n.layout != null) == l.key) {
                if (seen_item) continue;
                seen_item = true;
                const where = try path(c.a, s.where, n.name);
                const wrap = if (n.layout) |lay| lay.wrap else false;
                const inside = contentAllowed(s) or ch.kind == .instance;
                if (inside) {
                    try c.add(.{
                        .kind = .list,
                        .detail = if (ch.kind == .instance) "list of a component" else if (ch.kind == .text) "list of texts" else if (ch.children.len == 0) "list of images" else "list of look-alike frames",
                        .where = try std.fmt.allocPrint(c.a, "{s} ({d} × {s})", .{ where, l.count, ch.name }),
                        .rule = if (l.certain)
                            "one component repeated in an auto layout → a list"
                        else if (ch.kind == .instance)
                            "one component repeated without auto layout → a list"
                        else
                            "look-alike siblings repeated → a list",
                        .confidence = if (l.certain) 0.9 else 0.7,
                        .resolver = if (l.certain) .certain else .agent,
                    });
                    try c.add(.{
                        .kind = .validation,
                        .detail = if (wrap) "list bounds (open max)" else "list bounds",
                        .where = try std.fmt.allocPrint(c.a, "{s}: {s}", .{ where, if (wrap) "1 or more" else try std.fmt.allocPrint(c.a, "1 to {d}", .{l.count}) }),
                        .rule = if (wrap) "a wrapping auto layout → no maximum" else "the placeholder count → maximum, one → minimum",
                        .confidence = if (l.certain) 0.85 else 0.65,
                        .resolver = if (l.certain) .certain else .agent,
                    });
                }
                var item = s;
                item.where = try path(c.a, where, "[item]");
                try walkNode(c, item, ch);
                continue;
            }
        }
        try walkNode(c, s, ch);
    }
}

fn walkNode(c: *Ctx, s0: Scope, n: *const Node) anyerror!void {
    var s = s0;
    const own_bind = s.owner_root and contentAllowed(s);
    if (!n.visible) {
        if (n.bind.visible != null and own_bind) {
            try switchField(c, s, n);
            s.optional = true;
            return walkInner(c, s, n);
        }
        if (hasContentHidden(n) and contentAllowed(s)) try c.add(.{
            .kind = .hidden,
            .detail = "hidden layer",
            .where = try path(c.a, s.where, n.name),
            .rule = "hidden in the design, no property shows it → stays hidden",
            .confidence = 0.75,
            .resolver = .agent,
        });
        return;
    }
    if (n.bind.visible != null) {
        if (own_bind) {
            try switchField(c, s, n);
            s.optional = true;
        } else if (contentAllowed(s)) try c.add(.{
            .kind = .nested_property,
            .detail = "boolean of a nested instance",
            .where = try path(c.a, s.where, n.name),
            .rule = "a nested instance's property: editable only if exposed, which Pubd does not record",
            .confidence = 0.6,
            .resolver = .agent,
        });
    }
    return walkInner(c, s, n);
}

fn hasContentHidden(n: *const Node) bool {
    if (n.kind == .text or isImage(n)) return true;
    for (n.children) |*ch| if (hasContentHidden(ch)) return true;
    return false;
}

fn switchField(c: *Ctx, s: Scope, n: *const Node) !void {
    const p = findProp(s.props, n.bind.visible.?);
    try c.add(.{
        .kind = .field,
        .detail = "switch",
        .where = try path(c.a, s.where, if (p) |pp| pp.name else n.name),
        .rule = "a layer shown or hidden by a boolean property → a switch",
        .confidence = 0.95,
        .resolver = .certain,
    });
    bumpBlock(c, s.block, "fields");
}

fn walkInner(c: *Ctx, s0: Scope, n: *const Node) anyerror!void {
    var s = s0;
    switch (n.kind) {
        .text => return textField(c, s, n),
        .instance => {
            const where = try path(c.a, s.where, n.name);
            if (n.bind.component) |pid| {
                if (s.owner_root and contentAllowed(s)) {
                    const p = findProp(s.props, pid);
                    if (p != null and p.?.options.len > 0) {
                        try c.add(.{
                            .kind = .field,
                            .detail = "choice",
                            .where = where,
                            .rule = "an instance swap's preferred instances → the allowed choices",
                            .confidence = 0.95,
                            .resolver = .certain,
                        });
                    } else {
                        try c.add(.{
                            .kind = .field,
                            .detail = "choice",
                            .where = where,
                            .rule = "an instance swap without preferred instances: no basis for the choices",
                            .confidence = 0.4,
                            .resolver = .person,
                            .question = "swap-choices",
                            .wording = try std.fmt.allocPrint(c.a, "Which components may editors pick for “{s}”? The design names no preferred ones.", .{n.name}),
                            .default = "swap-sets",
                        });
                    }
                    bumpBlock(c, s.block, "fields");
                } else if (contentAllowed(s)) try c.add(.{
                    .kind = .nested_property,
                    .detail = "swap of a nested instance",
                    .where = where,
                    .rule = "a nested instance's property: editable only if exposed, which Pubd does not record",
                    .confidence = 0.6,
                    .resolver = .agent,
                });
            }
            if (c.smart() and isButtonName(n.name) and hasContent(n)) {
                try c.add(.{
                    .kind = .field,
                    .detail = "link",
                    .where = where,
                    .rule = "an instance named like a button or link → a link target (the design holds no targets)",
                    .confidence = 0.75,
                    .resolver = .agent,
                });
                bumpBlock(c, s.block, "fields");
            }
            for (n.props) |pv| {
                if (isIdLike(pv.id)) continue;
                try c.add(.{
                    .kind = .nested_property,
                    .detail = "variant of a nested instance",
                    .where = where,
                    .rule = "a nested instance's variant stays as designed unless exposed (Pubd does not record exposure)",
                    .confidence = 0.6,
                    .resolver = .agent,
                });
            }
            if (isImage(n)) try imageField(c, s, n);
            s.props = try mainProps(c, n);
            s.owner_root = false;
            s.inside_instance = true;
            return walkChildren(c, s, n);
        },
        else => {
            if (isImage(n)) try imageField(c, s, n);
            if (n.children.len > 0) return walkChildren(c, s, n);
        },
    }
}

/// The block a section instance stands for, analysed the first time it is seen.
fn blockForInstance(c: *Ctx, n: *const Node, where: []const u8) ![]const u8 {
    const mc: ?*const Node = if (n.component) |id| c.nodes.get(id) else null;
    const set: ?*const Node = if (mc) |mn| c.set_of.get(mn.id) else null;
    const key = if (set) |st| st.id else if (mc) |mn| mn.id else n.component orelse try std.fmt.allocPrint(c.a, "name:{s}", .{n.name});
    if (c.blocks.getPtr(key)) |b| {
        b.uses += 1;
        return key;
    }
    const name = if (set) |st| st.name else if (mc) |mn| mn.name else n.name;
    const root = mc orelse n;
    try c.blocks.put(c.a, key, .{
        .key = key,
        .name = name,
        .source = if (mc != null) .component else .library,
        .sig = sig(root, 4, false),
        .uses = 1,
        .where = where,
        .words = try wordsOf(c.a, root),
        .loose = looseSig(root),
    });
    const bwhere = try std.fmt.allocPrint(c.a, "block “{s}”", .{name});
    try c.add(.{
        .kind = .block,
        .detail = if (mc != null) "component" else "library component",
        .where = try std.fmt.allocPrint(c.a, "{s} (first at {s})", .{ bwhere, where }),
        .rule = if (mc != null) "a section is a component → a block" else "a section is an instance of a component kept outside the file → a block",
        .confidence = if (mc != null) 0.95 else 0.9,
        .resolver = .certain,
    });
    const props = try mainProps(c, n);
    for (props) |p| {
        if (p.kind != .variant) continue;
        try c.add(.{
            .kind = .field,
            .detail = "choice",
            .where = try path(c.a, bwhere, p.name),
            .rule = "a variant property → a choice of the variants",
            .confidence = 0.95,
            .resolver = .certain,
        });
        bumpBlock(c, key, "fields");
        var generic = isGenericVariant(p.name);
        for (p.options) |o| {
            if (isGenericVariant(o)) generic = true;
        }
        if (generic) try c.add(.{
            .kind = .field,
            .detail = "choice labels",
            .where = try path(c.a, bwhere, p.name),
            .rule = "variant names say nothing (Property 1, Variant2): the agent labels them from how they look",
            .confidence = 0.6,
            .resolver = .agent,
        });
    }
    if (mc == null) for (n.props) |pv| {
        if (isIdLike(pv.id)) continue;
        try c.add(.{
            .kind = .field,
            .detail = "choice",
            .where = try path(c.a, bwhere, pv.id),
            .rule = "a variant set on the instance, its options unknown (main outside the file): the values used in the design",
            .confidence = 0.6,
            .resolver = .agent,
        });
        bumpBlock(c, key, "fields");
    };
    const s: Scope = .{
        .block = key,
        .where = bwhere,
        .props = props,
        .inside_instance = true,
    };
    if (isImage(root)) try imageField(c, s, root);
    try walkChildren(c, s, root);
    return key;
}

/// A section drawn without a component (smart mode): one block per structure.
fn drawnBlock(c: *Ctx, n: *const Node, where: []const u8, template: []const u8) ![]const u8 {
    const sg = sig(n, 4, true);
    if (c.comp_by_sig.get(sg)) |comp| {
        const set = c.set_of.get(comp.id);
        const key = if (set) |st| st.id else comp.id;
        const fresh = !c.blocks.contains(key);
        if (fresh) {
            try c.blocks.put(c.a, key, .{
                .key = key,
                .name = if (set) |st| st.name else comp.name,
                .source = .component,
                .sig = sig(comp, 4, false),
                .where = where,
            });
            const s: Scope = .{
                .block = key,
                .where = try std.fmt.allocPrint(c.a, "block “{s}”", .{comp.name}),
                .props = comp.properties,
                .inside_instance = true,
            };
            try walkChildren(c, s, comp);
        }
        bumpBlock(c, key, "uses");
        try c.add(.{
            .kind = .block,
            .detail = "detached copy",
            .where = where,
            .rule = try std.fmt.allocPrint(c.a, "same structure and size as component “{s}” → a detached copy of it", .{comp.name}),
            .confidence = 0.75,
            .resolver = .agent,
        });
        return key;
    }
    if (c.drawn.get(sg)) |key| {
        bumpBlock(c, key, "uses");
        try c.add(.{
            .kind = .block_merge,
            .detail = "repeated drawn section",
            .where = where,
            .rule = "the same drawn structure seen before → the same block, different content",
            .confidence = 0.75,
            .resolver = .agent,
        });
        return key;
    }
    const key = try std.fmt.allocPrint(c.a, "drawn:{x}", .{sg});
    try c.drawn.put(c.a, sg, key);
    try c.blocks.put(c.a, key, .{
        .key = key,
        .name = n.name,
        .source = .drawn,
        .sig = sg,
        .uses = 1,
        .where = where,
    });
    try c.add(.{
        .kind = .block,
        .detail = "drawn section",
        .where = where,
        .rule = "a full-width section drawn without a component: no basis for a block",
        .confidence = 0.5,
        .resolver = .person,
        .question = "drawn-section",
        .wording = try std.fmt.allocPrint(c.a, "“{s}” on {s} is drawn without a component. Make its text and images editable?", .{ n.name, template }),
        .default = "drawn-sections",
    });
    const s: Scope = .{
        .block = key,
        .where = try std.fmt.allocPrint(c.a, "drawn “{s}”", .{n.name}),
        .in_drawn = true,
    };
    if (isImage(n)) try imageField(c, s, n);
    try walkChildren(c, s, n);
    return key;
}

/// Strict mode: a drawn region is locked; only instances inside it carry content.
fn fixedRegion(c: *Ctx, n: *const Node, where: []const u8) !void {
    try c.add(.{
        .kind = .locked,
        .detail = "drawn region",
        .where = where,
        .rule = "layers drawn on a template outside instances → design, locked",
        .confidence = 0.9,
        .resolver = .certain,
    });
    const key = try std.fmt.allocPrint(c.a, "fixed:{s}", .{n.id});
    const s: Scope = .{
        .block = key,
        .where = where,
        .need_instance = true,
    };
    try walkChildren(c, s, n);
}

// ---------------------------------------------------------------------------------------
// Coverage: of the texts and images a visitor sees on a template, how many become content

fn cover(c: *Ctx, n: *const Node, editable: bool, inside: bool) void {
    if (!n.visible) return;
    const ed = if (c.smart()) editable or inside else inside;
    if (n.kind == .text) {
        c.cov.texts += 1;
        if (ed) c.cov.texts_editable += 1;
        return;
    }
    if (isImage(n) and @max(n.size.x, n.size.y) >= 32) {
        c.cov.images += 1;
        if (ed) c.cov.images_editable += 1;
    }
    for (n.children) |*ch| cover(c, ch, editable, inside or n.kind == .instance);
}

// ---------------------------------------------------------------------------------------
// Templates

const Stack = struct {
    node: *const Node,
    geometric: bool,
    members: []const *const Node,
};

fn autoStack(c: *Ctx, n: *const Node, width: f32, height: f32, depth: u32) !?Stack {
    if (n.layout) |lay| if (lay.mode == .vertical and n.size.x >= 0.8 * width and n.size.y >= 0.4 * height) {
        var members: std.ArrayList(*const Node) = .empty;
        for (n.children) |*ch| {
            if (ch.visible and !ch.absolute) try members.append(c.a, ch);
        }
        if (members.items.len >= 2) return .{
            .node = n,
            .geometric = false,
            .members = members.items,
        };
    };
    if (depth == 0) return null;
    var best: ?Stack = null;
    for (n.children) |*ch| {
        if (!ch.visible or !isBox(ch.kind)) continue;
        if (try autoStack(c, ch, width, height, depth - 1)) |st| {
            if (best == null or st.node.size.y > best.?.node.size.y) best = st;
        }
    }
    return best;
}

fn lessY(_: void, x: *const Node, y: *const Node) bool {
    return x.transform.f < y.transform.f;
}

fn geometricStack(c: *Ctx, t: *const Node) !?Stack {
    var root = t;
    // A single full-size wrapper: look inside it.
    var wrapper_count: usize = 0;
    var only: ?*const Node = null;
    for (t.children) |*ch| {
        if (!ch.visible) continue;
        wrapper_count += 1;
        only = ch;
    }
    if (wrapper_count == 1 and only.?.children.len > 0 and only.?.size.x >= 0.9 * t.size.x) root = only.?;
    var members: std.ArrayList(*const Node) = .empty;
    for (root.children) |*ch| {
        if (!ch.visible) continue;
        if (ch.size.x >= 0.9 * t.size.x and ch.size.y >= 40 and ch.size.y < 0.9 * t.size.y) try members.append(c.a, ch);
    }
    std.mem.sort(*const Node, members.items, {}, lessY);
    // Sections do not overlap much.
    var kept: std.ArrayList(*const Node) = .empty;
    var bottom: f32 = -std.math.inf(f32);
    for (members.items) |mm| {
        const top = mm.transform.f;
        if (top >= bottom - 0.1 * mm.size.y) {
            try kept.append(c.a, mm);
            bottom = top + mm.size.y;
        }
    }
    if (kept.items.len < 3) return null;
    return .{
        .node = root,
        .geometric = true,
        .members = kept.items,
    };
}

fn contains(hay: []const *const Node, n: *const Node) bool {
    for (hay) |h| if (h == n) return true;
    return false;
}

fn isAncestorOf(n: *const Node, target: *const Node) bool {
    if (n == target) return true;
    for (n.children) |*ch| if (isAncestorOf(ch, target)) return true;
    return false;
}

fn processTemplate(c: *Ctx, t: *const Node, page_name: []const u8) !void {
    const tname = try std.fmt.allocPrint(c.a, "“{s}”", .{t.name});
    const twhere = try path(c.a, page_name, t.name);
    var stack = try autoStack(c, t, t.size.x, t.size.y, 3);
    if (stack == null and c.smart()) stack = try geometricStack(c, t);
    var tpl: Template = .{
        .page = page_name,
        .name = t.name,
        .group = try normName(c.a, t.name),
        .breakpoint = breakpointOf(t.size.x),
        .width = t.size.x,
        .height = t.size.y,
        .stack = if (stack) |st| (if (st.geometric) "geometric" else "auto layout") else "none",
        .stack_layer = if (stack) |st| st.node.name else "",
    };
    try c.add(.{
        .kind = .template,
        .detail = tpl.stack,
        .where = twhere,
        .rule = "a top-level frame of page size → a template",
        .confidence = 0.85,
        .resolver = .certain,
    });
    if (dataKind(t.name)) |dk| try c.add(.{
        .kind = .template,
        .detail = "data-bound",
        .where = twhere,
        .rule = "a frame named for a kind of record: its texts are that record's fields, which the design cannot say",
        .confidence = 0.5,
        .resolver = .person,
        .question = "data-template",
        .wording = try std.fmt.allocPrint(c.a, "{s} looks like a {s} page. Bind its texts and images to {s} records rather than page content?", .{ tname, dk.label, dk.label }),
        .default = dk.id,
    });
    var allowed: std.ArrayList([]const u8) = .empty;
    var seq = std.hash.Wyhash.init(7);
    var drawn_members: u32 = 0;
    if (stack) |st| {
        for (st.members) |sec| {
            tpl.sections += 1;
            const where = try path(c.a, twhere, sec.name);
            var key: ?[]const u8 = null;
            if (sec.kind == .instance) {
                key = try blockForInstance(c, sec, where);
                tpl.section_blocks += 1;
                cover(c, sec, true, true);
            } else if (!hasContent(sec)) {
                try c.add(.{
                    .kind = .locked,
                    .detail = "decor",
                    .where = where,
                    .rule = "a layer with no text or image between sections → design, locked",
                    .confidence = 0.9,
                    .resolver = .certain,
                });
                tpl.locked += 1;
            } else if (c.smart()) {
                key = try drawnBlock(c, sec, where, tname);
                tpl.drawn_sections += 1;
                drawn_members += 1;
                cover(c, sec, true, false);
            } else {
                drawn_members += 1;
                try fixedRegion(c, sec, where);
                tpl.locked += 1;
                cover(c, sec, false, false);
            }
            if (key) |k| {
                seq.update(k);
                var dup = false;
                for (allowed.items) |x| {
                    if (std.mem.eql(u8, x, k)) dup = true;
                }
                if (!dup) try allowed.append(c.a, k);
            }
        }
        const all_blocks = drawn_members == 0 and tpl.section_blocks >= 2;
        const any_blocks = tpl.section_blocks >= 1 and tpl.section_blocks + drawn_members >= 2 or (c.smart() and drawn_members >= 2);
        const swhere = try path(c.a, twhere, st.node.name);
        if (all_blocks and !st.geometric) {
            tpl.open_area = true;
            try c.add(.{
                .kind = .open_area,
                .detail = "open area",
                .where = swhere,
                .rule = "section instances stacked in a vertical auto layout → an open area",
                .confidence = 0.9,
                .resolver = .certain,
            });
        } else if (any_blocks) {
            tpl.open_area = true;
            try c.add(.{
                .kind = .open_area,
                .detail = "open area",
                .where = swhere,
                .rule = if (st.geometric) "full-width sections stacked by position, no auto layout" else "a vertical stack mixing component sections and drawn sections",
                .confidence = 0.6,
                .resolver = .person,
                .question = "page-stack",
                .wording = try std.fmt.allocPrint(c.a, "{s} stacks {d} sections ({d} components, {d} drawn). Let editors add, reorder and remove sections here?", .{ tname, tpl.sections, tpl.section_blocks, drawn_members }),
                .default = "page-stacks",
            });
        }
        if (tpl.open_area) try c.add(.{
            .kind = .allowed_set,
            .detail = try std.fmt.allocPrint(c.a, "{d} blocks", .{allowed.items.len}),
            .where = swhere,
            .rule = "the section blocks used in an open area → the blocks allowed there",
            .confidence = 0.8,
            .resolver = .certain,
        });
    }
    // Everything on the template outside the stack.
    for (t.children) |*ch| {
        if (!ch.visible) continue;
        if (stack) |st| {
            if (contains(st.members, ch) or isAncestorOf(ch, st.node)) {
                if (ch != st.node and !contains(st.members, ch)) {
                    // A wrapper around the stack: its other children are outside too.
                    for (ch.children) |*inner| {
                        if (!inner.visible or isAncestorOf(inner, st.node) or contains(st.members, inner)) continue;
                        try outside(c, &tpl, inner, twhere, tname, t);
                    }
                }
                continue;
            }
        }
        try outside(c, &tpl, ch, twhere, tname, t);
    }
    tpl.allowed = blk: {
        var names: std.ArrayList([]const u8) = .empty;
        for (allowed.items) |k| {
            if (c.blocks.get(k)) |b| try names.append(c.a, b.name);
        }
        break :blk names.items;
    };
    tpl.seq = seq.final();
    try c.templates.append(c.a, tpl);
}

fn outside(c: *Ctx, tpl: *Template, n: *const Node, twhere: []const u8, tname: []const u8, t: *const Node) !void {
    const where = try path(c.a, twhere, n.name);
    if (n.kind == .instance) {
        _ = try blockForInstance(c, n, where);
        tpl.outside_blocks += 1;
        cover(c, n, true, true);
        try c.add(.{
            .kind = .block,
            .detail = if (isSharedPartName(n.name)) "shared part" else "fixed block",
            .where = where,
            .rule = if (isSharedPartName(n.name)) "an instance named nav, header, footer or menu outside the sections → one shared copy for the site" else "an instance on the template outside any open area → a fixed block",
            .confidence = if (isSharedPartName(n.name)) 0.7 else 0.85,
            .resolver = if (isSharedPartName(n.name)) .agent else .certain,
        });
        return;
    }
    const big = n.size.x >= 0.5 * t.size.x and n.size.y >= 60;
    if (c.smart() and big and n.children.len > 0 and hasContent(n)) {
        _ = try drawnBlock(c, n, where, tname);
        tpl.drawn_sections += 1;
        cover(c, n, true, false);
        return;
    }
    tpl.locked += 1;
    if (!c.smart() and hasContent(n) and n.children.len > 0) {
        try fixedRegion(c, n, where);
        cover(c, n, false, false);
        return;
    }
    cover(c, n, false, false);
    try c.add(.{
        .kind = .locked,
        .detail = if (n.kind == .text) "loose text" else "decor",
        .where = where,
        .rule = "layers drawn on a template outside instances → design, locked",
        .confidence = 0.9,
        .resolver = .certain,
    });
}

// ---------------------------------------------------------------------------------------
// Pages

fn pageRole(name: []const u8, top: usize) struct {
    role: []const u8,
    resolver: Resolver,
} {
    if (top == 0) return .{
        .role = "separator",
        .resolver = .certain,
    };
    const discarded = [_][]const u8{ "graveyard", "archive", "old", "trash", "unused", "wip", "scratch" };
    for (discarded) |w| {
        if (std.ascii.findIgnoreCase(name, w) != null) return .{
            .role = "discarded",
            .resolver = .agent,
        };
    }
    const library = [_][]const u8{ "component", "library", "design system", "assets", "icons", "styles" };
    for (library) |w| {
        if (std.ascii.findIgnoreCase(name, w) != null) return .{
            .role = "library",
            .resolver = .agent,
        };
    }
    if (std.ascii.findIgnoreCase(name, "cover") != null or std.ascii.findIgnoreCase(name, "thumbnail") != null) return .{
        .role = "cover",
        .resolver = .agent,
    };
    return .{
        .role = "site",
        .resolver = .agent,
    };
}

fn processPage(c: *Ctx, page: *const Node) !void {
    c.page = page.name;
    const role = pageRole(page.name, page.children.len);
    var info: PageInfo = .{
        .name = page.name,
        .role = role.role,
    };
    try c.add(.{
        .kind = .page_role,
        .detail = role.role,
        .where = page.name,
        .rule = "the page's name and contents say what it is for",
        .confidence = if (role.resolver == .certain) 0.95 else 0.75,
        .resolver = role.resolver,
    });
    const first = c.decisions.items.len - 1;
    if (std.mem.eql(u8, role.role, "site")) {
        for (page.children) |*ch| {
            if (!ch.visible) continue;
            const page_sized = ch.size.x >= 300 and ch.size.y >= 300;
            switch (ch.kind) {
                .frame => if (page_sized) {
                    info.templates += 1;
                    try processTemplate(c, ch, page.name);
                } else {
                    info.fragments += 1;
                    try c.add(.{
                        .kind = .fragment,
                        .detail = "small frame",
                        .where = try path(c.a, page.name, ch.name),
                        .rule = "a top-level frame smaller than a page → an asset or note, not a template",
                        .confidence = 0.75,
                        .resolver = .agent,
                    });
                },
                .component => if (ch.size.y >= 1000 and ch.size.x >= 300) {
                    info.templates += 1;
                    try processTemplate(c, ch, page.name);
                } else {
                    info.components += 1;
                },
                .component_set => info.components += 1,
                else => info.loose += 1,
            }
        }
        if (info.loose > 0) try c.add(.{
            .kind = .fragment,
            .detail = "loose layers",
            .where = try std.fmt.allocPrint(c.a, "{s}: {d} loose groups, texts and shapes on the canvas", .{ page.name, info.loose }),
            .rule = "layers lying on the canvas outside any frame are notes and spare parts, not pages",
            .confidence = 0.8,
            .resolver = .agent,
        });
    } else {
        for (page.children) |*ch| {
            if (ch.kind == .component or ch.kind == .component_set) info.components += 1;
        }
    }
    for (c.decisions.items[first..]) |d| switch (d.resolver) {
        .certain => info.certain += 1,
        .agent => info.agent += 1,
        .person => info.person += 1,
    };
    try c.pages.append(c.a, info);
}

/// After every page: templates that are copies or breakpoints of each other, and blocks
/// that look alike.
fn crossChecks(c: *Ctx) !void {
    c.page = "(whole file)";
    // Templates by name group.
    const ts = c.templates.items;
    var done = try c.a.alloc(bool, ts.len);
    @memset(done, false);
    for (ts, 0..) |t, i| {
        if (done[i]) continue;
        var same_bp: u32 = 0;
        var other_bp: u32 = 0;
        var differ = false;
        var open_all = t.open_area;
        var differ_name: []const u8 = "";
        var differ_page: []const u8 = "";
        for (ts[i + 1 ..], i + 1..) |u, j| {
            if (!std.mem.eql(u8, t.group, u.group) or t.group.len == 0) continue;
            done[j] = true;
            if (std.mem.eql(u8, t.breakpoint, u.breakpoint)) {
                same_bp += 1;
                if (u.seq != t.seq) {
                    differ = true;
                    differ_name = u.name;
                    differ_page = u.page;
                }
                open_all = open_all and u.open_area;
            } else other_bp += 1;
        }
        if (same_bp > 0) {
            if (differ and !open_all and c.smart()) {
                try c.add(.{
                    .kind = .template_copy,
                    .detail = "copies differ",
                    .where = try std.fmt.allocPrint(c.a, "“{s}” and {d} more", .{ t.name, same_bp }),
                    .rule = "frames named alike with different sections and no open area: no basis to tell template from draft",
                    .confidence = 0.4,
                    .resolver = .person,
                    .question = "copy-differs",
                    .wording = try std.fmt.allocPrint(c.a, "“{s}” ({s}) and “{s}” ({s}) share a name but not their sections. Are they entries of one template, or is one of them the template?", .{ t.name, t.page, differ_name, differ_page }),
                });
            } else try c.add(.{
                .kind = .template_copy,
                .detail = "copies are entries",
                .where = try std.fmt.allocPrint(c.a, "“{s}” and {d} more", .{ t.name, same_bp }),
                .rule = if (differ) "frames named alike whose sections differ inside an open area → entries of one template" else "frames named alike with the same sections → entries of one template",
                .confidence = 0.75,
                .resolver = .agent,
            });
        }
        if (other_bp > 0) try c.add(.{
            .kind = .template_copy,
            .detail = "breakpoints",
            .where = try std.fmt.allocPrint(c.a, "“{s}” at {d} other width(s)", .{ t.name, other_bp }),
            .rule = "the same name at desktop and mobile width → one template drawn at two widths",
            .confidence = 0.7,
            .resolver = .agent,
        });
    }
    // Blocks with one name: look-alikes, one question per name.
    const bs = c.blocks.values();
    for (bs, 0..) |*b, i| {
        if (b.source == .drawn or b.merged_into != null) continue;
        var n_same: u32 = 1;
        var all_same = true;
        var loose_same = true;
        var spots: std.ArrayList(u8) = .empty;
        try spots.print(c.a, "{d}", .{b.fields});
        for (bs[i + 1 ..]) |*o| {
            if (o.source == .drawn or o.merged_into != null) continue;
            if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, b.name, " "), std.mem.trim(u8, o.name, " "))) continue;
            o.merged_into = b.key;
            n_same += 1;
            if (o.sig != b.sig) all_same = false;
            if (o.loose != b.loose) loose_same = false;
            try spots.print(c.a, ", {d}", .{o.fields});
            // Words of the whole group, for matching breakpoints below.
            b.words = try concatWords(c.a, b.words, o.words);
        }
        if (n_same < 2) continue;
        if (all_same) {
            try c.add(.{
                .kind = .block_merge,
                .detail = "look-alike, same structure",
                .where = try std.fmt.allocPrint(c.a, "{d} components called “{s}”", .{ n_same, b.name }),
                .rule = "components with one name and one structure → one block; their differences are content",
                .confidence = 0.75,
                .resolver = .agent,
            });
        } else if (loose_same and c.smart()) {
            try c.add(.{
                .kind = .block_merge,
                .detail = "look-alike, lists differ in length",
                .where = try std.fmt.allocPrint(c.a, "{d} components called “{s}”", .{ n_same, b.name }),
                .rule = "components with one name whose structure differs only in how many items a row repeats → one block with a list",
                .confidence = 0.7,
                .resolver = .agent,
            });
        } else try c.add(.{
            .kind = .block_merge,
            .detail = "look-alike, different structure",
            .where = try std.fmt.allocPrint(c.a, "{d} components called “{s}”", .{ n_same, b.name }),
            .rule = "components with one name but different structure: one block or several is a product call",
            .confidence = 0.4,
            .resolver = .person,
            .question = "lookalike",
            .wording = try std.fmt.allocPrint(c.a, "{d} components are all called “{s}” but are built differently ({s} editable spots). One block with options, or {d} blocks?", .{ n_same, b.name, spots.items, n_same }),
        });
    }
    // The same block drawn at two widths ("SS - Desktop", "SS - Mobile").
    for (bs, 0..) |*b, i| {
        if (b.source == .drawn or b.merged_into != null) continue;
        const bw = breakpointWord(b.name) orelse continue;
        const bn = try normName(c.a, b.name);
        if (bn.len == 0) continue;
        for (bs[i + 1 ..]) |*o| {
            if (o.source == .drawn or o.merged_into != null) continue;
            const ow = breakpointWord(o.name) orelse continue;
            if (std.mem.eql(u8, bw, ow)) continue;
            if (!std.mem.eql(u8, bn, try normName(c.a, o.name))) continue;
            o.merged_into = b.key;
            const ov = overlap(b.words, o.words);
            if (ov >= 0.8) {
                try c.add(.{
                    .kind = .block_merge,
                    .detail = "breakpoint pair, matched by words",
                    .where = try std.fmt.allocPrint(c.a, "“{s}” and “{s}”", .{ b.name, o.name }),
                    .rule = "the same block at two widths whose texts say the same words → one block; fields matched by their words, the rest shown at one width only",
                    .confidence = 0.8,
                    .resolver = .agent,
                });
            } else if (b.texts == o.texts and b.images == o.images) {
                try c.add(.{
                    .kind = .block_merge,
                    .detail = "breakpoint pair, matched in order",
                    .where = try std.fmt.allocPrint(c.a, "“{s}” and “{s}”", .{ b.name, o.name }),
                    .rule = "the same block at two widths with as many texts and images → one block, fields matched in order",
                    .confidence = 0.65,
                    .resolver = .agent,
                });
            } else try c.add(.{
                .kind = .block_merge,
                .detail = "breakpoint pair, fields differ",
                .where = try std.fmt.allocPrint(c.a, "“{s}” and “{s}”", .{ b.name, o.name }),
                .rule = "the same block at two widths with different texts and images and few shared words: no basis to match fields",
                .confidence = 0.45,
                .resolver = .person,
                .question = "breakpoint-mismatch",
                .wording = try std.fmt.allocPrint(c.a, "“{s}” has {d} texts and {d} images; “{s}” has {d} and {d}, with different words. Which fields are the same content at the two widths?", .{ b.name, b.texts, b.images, o.name, o.texts, o.images }),
            });
        }
    }
}

fn wordsOf(a: A, n: *const Node) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    try collectWords(a, n, &out);
    return out.items;
}

fn collectWords(a: A, n: *const Node, out: *std.ArrayList([]const u8)) !void {
    if (!n.visible) return;
    if (n.text) |t| {
        var it = std.mem.tokenizeAny(u8, t.text, " \n\t,.:;!?()→-");
        while (it.next()) |w| try out.append(a, try lower(a, w));
        return;
    }
    for (n.children) |*ch| try collectWords(a, ch, out);
}

fn concatWords(a: A, x: []const []const u8, y: []const []const u8) ![]const []const u8 {
    const out = try a.alloc([]const u8, x.len + y.len);
    @memcpy(out[0..x.len], x);
    @memcpy(out[x.len..], y);
    return out;
}

/// Of the smaller set of texts, the share whose words appear in the other.
fn overlap(x: []const []const u8, y: []const []const u8) f32 {
    if (x.len == 0 or y.len == 0) return 0;
    const small = if (x.len <= y.len) x else y;
    const big = if (x.len <= y.len) y else x;
    var hit: u32 = 0;
    for (small) |w| {
        for (big) |v| {
            if (std.mem.eql(u8, w, v)) {
                hit += 1;
                break;
            }
        }
    }
    return @as(f32, @floatFromInt(hit)) / @as(f32, @floatFromInt(small.len));
}

// ---------------------------------------------------------------------------------------
// Summary

const FieldCounts = struct {
    text: u32 = 0,
    rich_text: u32 = 0,
    multi_line: u32 = 0,
    image: u32 = 0,
    link: u32 = 0,
    @"switch": u32 = 0,
    choice: u32 = 0,
    total: u32 = 0,
};

const ValidationCounts = struct {
    required: u32 = 0,
    optional: u32 = 0,
    length_guide: u32 = 0,
    crop_ratio: u32 = 0,
    minimum_size: u32 = 0,
    list_bounds: u32 = 0,
    list_bounds_open: u32 = 0,
};

const QuestionGroup = struct {
    type: []const u8,
    count: u32,
    default: ?[]const u8,
    default_wording: ?[]const u8,
    examples: []const Example,
};

const Example = struct {
    where: []const u8,
    wording: []const u8,
};

const Summary = struct {
    mode: Mode,
    templates: u32 = 0,
    template_groups: u32 = 0,
    blocks: u32 = 0,
    blocks_component: u32 = 0,
    blocks_library: u32 = 0,
    blocks_drawn: u32 = 0,
    blocks_after_merge: u32 = 0,
    fields: FieldCounts = .{},
    fields_after_merge: u32 = 0,
    open_areas: u32 = 0,
    open_areas_certain: u32 = 0,
    lists: u32 = 0,
    lists_certain: u32 = 0,
    validations: ValidationCounts = .{},
    locked: u32 = 0,
    hidden_layers: u32 = 0,
    nested_properties: u32 = 0,
    decisions: u32 = 0,
    certain: u32 = 0,
    agent: u32 = 0,
    person: u32 = 0,
    coverage: Coverage = .{},
    field_names: Names = .{},
    questions: []const QuestionGroup = &.{},
    defaults_triggered: []const []const u8 = &.{},
    residual_questions: u32 = 0,
    questions_after_cascade: u32 = 0,
};

fn summarize(c: *Ctx) !Summary {
    var s: Summary = .{
        .mode = c.mode,
        .coverage = c.cov,
        .field_names = c.names,
    };
    s.templates = @intCast(c.templates.items.len);
    {
        var groups: std.StringHashMapUnmanaged(void) = .empty;
        for (c.templates.items) |t| try groups.put(c.a, t.group, {});
        s.template_groups = groups.count();
    }
    var merged_fields: u32 = 0;
    for (c.blocks.values()) |b| {
        if (b.source == .fixed or std.mem.startsWith(u8, b.key, "fixed:")) continue;
        s.blocks += 1;
        switch (b.source) {
            .component => s.blocks_component += 1,
            .library => s.blocks_library += 1,
            .drawn => s.blocks_drawn += 1,
            .fixed => {},
        }
        if (b.merged_into == null) s.blocks_after_merge += 1 else merged_fields += b.fields;
    }
    var by_q: std.StringArrayHashMapUnmanaged(std.ArrayList(Decision)) = .empty;
    for (c.decisions.items) |d| {
        s.decisions += 1;
        switch (d.resolver) {
            .certain => s.certain += 1,
            .agent => s.agent += 1,
            .person => s.person += 1,
        }
        switch (d.kind) {
            .field => {
                const kinds = [_]struct {
                    name: []const u8,
                    f: []const u8,
                }{
                    .{
                        .name = "text",
                        .f = "text",
                    },
                    .{
                        .name = "rich text",
                        .f = "rich_text",
                    },
                    .{
                        .name = "multi-line",
                        .f = "multi_line",
                    },
                    .{
                        .name = "image",
                        .f = "image",
                    },
                    .{
                        .name = "link",
                        .f = "link",
                    },
                    .{
                        .name = "switch",
                        .f = "switch",
                    },
                    .{
                        .name = "choice",
                        .f = "choice",
                    },
                };
                inline for (kinds) |k| {
                    if (std.mem.eql(u8, d.detail, k.name)) {
                        @field(s.fields, k.f) += 1;
                        s.fields.total += 1;
                    }
                }
            },
            .open_area => {
                s.open_areas += 1;
                if (d.resolver == .certain) s.open_areas_certain += 1;
            },
            .list => {
                s.lists += 1;
                if (d.resolver == .certain) s.lists_certain += 1;
            },
            .validation => {
                if (std.mem.eql(u8, d.detail, "required")) s.validations.required += 1;
                if (std.mem.eql(u8, d.detail, "optional")) s.validations.optional += 1;
                if (std.mem.eql(u8, d.detail, "length guide")) s.validations.length_guide += 1;
                if (std.mem.eql(u8, d.detail, "crop ratio")) s.validations.crop_ratio += 1;
                if (std.mem.eql(u8, d.detail, "minimum size")) s.validations.minimum_size += 1;
                if (std.mem.eql(u8, d.detail, "list bounds")) s.validations.list_bounds += 1;
                if (std.mem.eql(u8, d.detail, "list bounds (open max)")) s.validations.list_bounds_open += 1;
            },
            .locked => s.locked += 1,
            .hidden => s.hidden_layers += 1,
            .nested_property => s.nested_properties += 1,
            else => {},
        }
        if (d.resolver == .person) {
            const q = d.question orelse "other";
            const gop = try by_q.getOrPut(c.a, q);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(c.a, d);
        }
    }
    s.fields_after_merge = s.fields.total -| merged_fields;
    var groups: std.ArrayList(QuestionGroup) = .empty;
    var triggered: std.ArrayList([]const u8) = .empty;
    var residual: u32 = 0;
    for (by_q.keys(), by_q.values()) |q, list| {
        var ex: std.ArrayList(Example) = .empty;
        // Examples from different pages first.
        for (list.items) |d| {
            if (ex.items.len >= 5) break;
            try ex.append(c.a, .{
                .where = d.where,
                .wording = d.wording orelse "",
            });
        }
        const def = list.items[0].default;
        var def_wording: ?[]const u8 = null;
        if (def) |id| {
            for (defaults) |dd| {
                if (std.mem.eql(u8, dd.id, id)) def_wording = dd.wording;
            }
        }
        for (list.items) |d| {
            const id = d.default orelse {
                residual += 1;
                continue;
            };
            var seen = false;
            for (triggered.items) |t| {
                if (std.mem.eql(u8, t, id)) seen = true;
            }
            if (!seen) try triggered.append(c.a, id);
        }
        try groups.append(c.a, .{
            .type = q,
            .count = @intCast(list.items.len),
            .default = def,
            .default_wording = def_wording,
            .examples = ex.items,
        });
    }
    s.questions = groups.items;
    s.defaults_triggered = triggered.items;
    s.residual_questions = residual;
    s.questions_after_cascade = residual + @as(u32, @intCast(triggered.items.len));
    return s;
}

const BlockOut = struct {
    name: []const u8,
    source: Source,
    fields: u32,
    texts: u32,
    images: u32,
    uses: u32,
    merged_into: ?[]const u8,
    first_seen: []const u8,
};

const Run = struct {
    summary: Summary,
    pages: []const PageInfo,
    templates: []const Template,
    blocks: []const BlockOut,
    decisions: []const Decision,
};

fn run(a: A, doc: *const m.Document, mode: Mode) !Run {
    var c: Ctx = .{
        .a = a,
        .mode = mode,
    };
    for (doc.pages) |*p| try index(&c, p);
    // Components by structure, for detached copies.
    var it = c.nodes.valueIterator();
    while (it.next()) |n| {
        if (n.*.kind == .component and n.*.size.x >= 300) try c.comp_by_sig.put(a, sig(n.*, 4, true), n.*);
    }
    for (doc.pages) |*p| try processPage(&c, p);
    try crossChecks(&c);
    const summary = try summarize(&c);
    var blocks: std.ArrayList(BlockOut) = .empty;
    for (c.blocks.values()) |b| {
        if (std.mem.startsWith(u8, b.key, "fixed:")) continue;
        try blocks.append(a, .{
            .name = b.name,
            .source = b.source,
            .fields = b.fields,
            .texts = b.texts,
            .images = b.images,
            .uses = b.uses,
            .merged_into = if (b.merged_into) |k| (if (c.blocks.get(k)) |mb| mb.name else k) else null,
            .first_seen = b.where,
        });
    }
    return .{
        .summary = summary,
        .pages = c.pages.items,
        .templates = c.templates.items,
        .blocks = blocks.items,
        .decisions = c.decisions.items,
    };
}

// ---------------------------------------------------------------------------------------

fn load(io: Io, gpa: A, dir: []const u8) !m.Document {
    const cwd = Dir.cwd();
    const doc_path = try std.fs.path.join(gpa, &.{ dir, "document.json" });
    defer gpa.free(doc_path);
    const json = try cwd.readFileAlloc(io, doc_path, gpa, .limited(max_file));
    defer gpa.free(json);
    var doc = try engine.pubd_read.fromJson(gpa, json, .{});
    errdefer doc.deinit();
    for (doc.chunks, doc.pages) |ch, *pg| {
        const pp = try std.fs.path.join(gpa, &.{ dir, ch.src });
        defer gpa.free(pp);
        const pj = try cwd.readFileAlloc(io, pp, gpa, .limited(max_file));
        defer gpa.free(pj);
        pg.* = try engine.pubd_read.pageFromJson(gpa, doc.arena.allocator(), pj, .{});
    }
    return doc;
}

fn printSummary(w: *Io.Writer, label: []const u8, s: Summary) !void {
    try w.print("{s} [{s}] templates {d} (groups {d}) | blocks {d} (component {d}, library {d}, drawn {d}; after merge {d})\n", .{ label, @tagName(s.mode), s.templates, s.template_groups, s.blocks, s.blocks_component, s.blocks_library, s.blocks_drawn, s.blocks_after_merge });
    try w.print("  fields {d} (after merge {d}): text {d}, rich {d}, multi-line {d}, image {d}, link {d}, switch {d}, choice {d}\n", .{ s.fields.total, s.fields_after_merge, s.fields.text, s.fields.rich_text, s.fields.multi_line, s.fields.image, s.fields.link, s.fields.@"switch", s.fields.choice });
    try w.print("  open areas {d} (certain {d}) | lists {d} (certain {d}) | locked {d} | hidden {d} | nested props {d}\n", .{ s.open_areas, s.open_areas_certain, s.lists, s.lists_certain, s.locked, s.hidden_layers, s.nested_properties });
    const v = s.validations;
    try w.print("  validations: required {d}, optional {d}, length {d}, crop {d}, min size {d}, list bounds {d} + open {d}\n", .{ v.required, v.optional, v.length_guide, v.crop_ratio, v.minimum_size, v.list_bounds, v.list_bounds_open });
    try w.print("  decisions {d}: certain {d}, agent {d}, person {d} | after cascade {d} ({d} defaults + {d} residual)\n", .{ s.decisions, s.certain, s.agent, s.person, s.questions_after_cascade, s.defaults_triggered.len, s.residual_questions });
    try w.print("  coverage: texts {d}/{d}, images {d}/{d} | field names: property {d}, layer {d}, none {d}\n", .{ s.coverage.texts_editable, s.coverage.texts, s.coverage.images_editable, s.coverage.images, s.field_names.property, s.field_names.layer, s.field_names.none });
    for (s.questions) |q| try w.print("  Q {s}: {d}{s}\n", .{ q.type, q.count, if (q.default != null) " (default)" else "" });
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    var out_buf: [4096]u8 = undefined;
    var stdout: Io.File.Writer = .init(.stdout(), io, &out_buf);
    const w = &stdout.interface;
    defer w.flush() catch {};
    if (args.len < 4) {
        try w.writeAll("usage: model-inference <label> <doc.pubd-dir> <out.json>\n");
        try w.flush();
        std.process.exit(2);
    }
    var doc = try load(io, gpa, args[2]);
    defer doc.deinit();
    const strict = try run(arena, &doc, .strict);
    const smart = try run(arena, &doc, .smart);
    try printSummary(w, args[1], strict.summary);
    try printSummary(w, args[1], smart.summary);
    const out = .{
        .label = args[1],
        .file = args[2],
        .document = doc.name,
        .note = "strict: only the rules written in the spec; smart: plus the rules this measurement proposes. Decisions, templates and blocks are listed for the smart run.",
        .defaults = defaults,
        .strict = strict.summary,
        .smart = smart.summary,
        .pages = smart.pages,
        .templates = smart.templates,
        .blocks = smart.blocks,
        .decisions = smart.decisions,
    };
    const json = try std.json.Stringify.valueAlloc(arena, out, .{
        .whitespace = .indent_1,
    });
    try Dir.cwd().writeFile(io, .{
        .sub_path = args[3],
        .data = json,
    });
}
