//! Pubd JSON (`document.json`) into a document.

const std = @import("std");
const m = @import("model.zig");
const geom = @import("../raster/geom.zig");
const jv = @import("../jv.zig");

const Value = jv.Value;
const get = jv.get;
const str = jv.str;
const boolean = jv.boolean;
const num = jv.num;
const numberOf = jv.numberOf;
const arr = jv.arr;

pub const Error = error{
    NotPubd,
    UnsupportedVersion,
    BadNode,
    /// A number that is not finite: `nan` or `inf` written as a bare word (not JSON),
    /// or a number too large for the model. `Problem` says where.
    NotFinite,
} || std.mem.Allocator.Error || std.json.ParseError(std.json.Scanner);

/// Why `fromJsonReport` refused a file, in words.
pub const Problem = struct {
    buf: [200]u8 = undefined,
    len: usize = 0,

    pub fn message(self: *const Problem) []const u8 {
        return self.buf[0..self.len];
    }

    fn set(self: *Problem, comptime fmt: []const u8, args: anytype) void {
        self.len = if (std.fmt.bufPrint(&self.buf, fmt, args)) |out| out.len else |_| 0;
    }
};

/// The newest draft this reader knows (older ones open too).
pub const version: i64 = 2;

/// How a file is read.
pub const Options = struct {
    /// Says what is wrong when the file has a number that is not finite
    /// (`error.NotFinite`).
    problem: ?*Problem = null,
};

/// Parses `document.json`. Everything lives in the document's arena.
///
/// A document kept page by page (pages with `src`) reads without its pages' nodes:
/// `doc.chunks` says where they are, and `pageFromJson` reads one.
pub fn fromJson(gpa: std.mem.Allocator, json: []const u8, options: Options) Error!m.Document {
    // The parsed JSON is several times the size of the model: it lives in scratch
    // memory, and the document keeps a copy of what it built.
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    const tmp = try build(scratch.allocator(), json, options.problem);
    var doc: m.Document = .{
        .arena = .init(gpa),
    };
    errdefer doc.deinit();
    const a = doc.arena.allocator();
    doc.name = try a.dupe(u8, tmp.name);
    doc.pages = try m.deepCopy(a, tmp.pages);
    doc.styles = try m.deepCopy(a, tmp.styles);
    doc.assets = try m.deepCopy(a, tmp.assets);
    doc.shared = try m.deepCopy(a, tmp.shared);
    doc.chunks = try m.deepCopy(a, tmp.chunks);
    doc.glyphs = try m.deepCopy(a, tmp.glyphs);
    doc.fonts = try m.deepCopy(a, tmp.fonts);
    doc.collections = try m.deepCopy(a, tmp.collections);
    doc.variables = try m.deepCopy(a, tmp.variables);
    doc.components = try m.deepCopy(a, tmp.components);
    return doc;
}

/// A page's own file (`src` of a page in a document kept page by page): the page node
/// and everything on it, built in `a` (parsed in scratch memory).
pub fn pageFromJson(gpa: std.mem.Allocator, a: std.mem.Allocator, json: []const u8, options: Options) Error!m.Node {
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    const sa = scratch.allocator();
    const root = try parse(sa, json, options.problem);
    const page = try node(sa, root);
    var one = [1]m.Node{page};
    try checkFinite(&.{
        .arena = undefined,
        .pages = &one,
    }, options.problem);
    return m.deepCopy(a, page);
}

/// Where a page file's top-level nodes are, without reading them: the byte offsets of
/// the root's `children` array (its `[` and just past its `]`), then each element's
/// start and end. Empty when the root has no `children` array. A page read in pieces
/// (`Session.beginPage`) takes the file less that array, then each element.
///
/// A byte scan (strings skipped, brackets counted): it reads a big page's file several
/// times faster than the JSON scanner. What it does not find plainly (a key spelled
/// with escapes) the JSON scanner looks for; the nodes are checked when read.
pub fn childSpans(gpa: std.mem.Allocator, json: []const u8) ![]u32 {
    return scanSpans(gpa, json) catch |e| switch (e) {
        error.NotFound => childSpansScanner(gpa, json),
        else => e,
    };
}

fn skipWs(json: []const u8, from: usize) usize {
    var i = from;
    while (i < json.len) : (i += 1) switch (json[i]) {
        ' ', '\t', '\n', '\r' => {},
        else => return i,
    };
    return i;
}

const Lanes = @Vector(16, u8);

/// The first byte at or after `from` that is one of `set` (`json.len`: none), sixteen
/// bytes a step.
fn nextOf(json: []const u8, from: usize, comptime set: []const u8) usize {
    var i = from;
    while (i + 16 <= json.len) : (i += 16) {
        const v: Lanes = json[i..][0..16].*;
        var hit: @Vector(16, bool) = @splat(false);
        inline for (set) |c| hit = hit | (v == @as(Lanes, @splat(c)));
        const bits: u16 = @bitCast(hit);
        if (bits != 0) return i + @ctz(bits);
    }
    while (i < json.len) : (i += 1) inline for (set) |c| {
        if (json[i] == c) return i;
    };
    return json.len;
}

/// The closing quote of the string whose opening quote is at `at`.
fn stringEnd(json: []const u8, at: usize) error{BadNode}!usize {
    var i = at + 1;
    while (true) {
        i = nextOf(json, i, "\"\\");
        if (i >= json.len) return error.BadNode;
        if (json[i] == '"') return i;
        i += 2;
    }
}

/// Just past the value that starts at `at`.
fn valueEnd(json: []const u8, at: usize) error{BadNode}!usize {
    switch (json[at]) {
        '"' => return try stringEnd(json, at) + 1,
        '{', '[' => {
            var depth: usize = 0;
            var i = at;
            while (true) {
                i = nextOf(json, i, "\"{}[]");
                if (i >= json.len) return error.BadNode;
                switch (json[i]) {
                    '"' => i = try stringEnd(json, i),
                    '{', '[' => depth += 1,
                    else => {
                        depth -= 1;
                        if (depth == 0) return i + 1;
                    },
                }
                i += 1;
            }
        },
        else => {
            var i = at;
            while (i < json.len) : (i += 1) switch (json[i]) {
                ',', '}', ']', ' ', '\t', '\n', '\r' => return i,
                else => {},
            };
            return i;
        },
    }
}

fn scanSpans(gpa: std.mem.Allocator, json: []const u8) ![]u32 {
    var out: std.ArrayList(u32) = .empty;
    errdefer out.deinit(gpa);
    var i = skipWs(json, 0);
    if (i >= json.len or json[i] != '{') return error.BadNode;
    i += 1;
    while (true) {
        i = skipWs(json, i);
        if (i >= json.len) return error.BadNode;
        switch (json[i]) {
            '}' => return error.NotFound,
            ',' => {
                i += 1;
                continue;
            },
            '"' => {},
            else => return error.BadNode,
        }
        const key_end = try stringEnd(json, i);
        const key = json[i + 1 .. key_end];
        i = skipWs(json, key_end + 1);
        if (i >= json.len or json[i] != ':') return error.BadNode;
        i = skipWs(json, i + 1);
        if (i >= json.len) return error.BadNode;
        if (!std.mem.eql(u8, key, "children") or json[i] != '[') {
            i = try valueEnd(json, i);
            continue;
        }
        try out.appendSlice(gpa, &.{ @intCast(i), 0 });
        i += 1;
        while (true) {
            i = skipWs(json, i);
            if (i >= json.len) return error.BadNode;
            switch (json[i]) {
                ']' => {
                    out.items[1] = @intCast(i + 1);
                    return out.toOwnedSlice(gpa);
                },
                ',' => {
                    i += 1;
                    continue;
                },
                else => {},
            }
            const start = i;
            i = try valueEnd(json, i);
            try out.appendSlice(gpa, &.{ @intCast(start), @intCast(i) });
        }
    }
}

/// `childSpans` by the JSON scanner (keys spelled with escapes; and the check of the scan).
pub fn childSpansScanner(gpa: std.mem.Allocator, json: []const u8) ![]u32 {
    var out: std.ArrayList(u32) = .empty;
    errdefer out.deinit(gpa);
    var sc: std.json.Scanner = .initCompleteInput(gpa, json);
    defer sc.deinit();
    if (try sc.next() != .object_begin) return error.BadNode;
    var keys: std.heap.ArenaAllocator = .init(gpa);
    defer keys.deinit();
    while (true) {
        const key = switch (try sc.nextAlloc(keys.allocator(), .alloc_if_needed)) {
            .object_end => break,
            .string, .allocated_string => |k| k,
            else => return error.BadNode,
        };
        if (!std.mem.eql(u8, key, "children") or try sc.peekNextTokenType() != .array_begin) {
            try sc.skipValue();
            continue;
        }
        const open = sc.cursor;
        _ = try sc.next();
        try out.appendSlice(gpa, &.{ @intCast(open), 0 });
        while (try sc.peekNextTokenType() != .array_end) {
            const start = sc.cursor;
            try sc.skipValue();
            try out.appendSlice(gpa, &.{ @intCast(start), @intCast(sc.cursor) });
        }
        _ = try sc.next();
        out.items[1] = @intCast(sc.cursor);
        break;
    }
    return out.toOwnedSlice(gpa);
}

test "childSpans: the byte scan finds what the JSON scanner finds" {
    const gpa = std.testing.allocator;
    const cases = [_][]const u8{
        \\{"id":"0:1","name":"P [x] {y}","children":[{"id":"1","children":[{"a":"]"}]},  {"id":"2","s":"q\"}"} ,[1,[2]] ],"background":[1,1,1]}
        ,
        \\ { "children" : [ ] , "id" : "x" }
        ,
        \\{"data":{"children":[1]},"children":[ 1 , true,"s",{"k":{}}]}
        ,
        \\{"id":"x","name":"no kids"}
        ,
        \\{"\\u0063hildren":[{"id":"1"}]}
        ,
    };
    for (cases) |json| {
        const a = try childSpans(gpa, json);
        defer gpa.free(a);
        const b = try childSpansScanner(gpa, json);
        defer gpa.free(b);
        try std.testing.expectEqualSlices(u32, b, a);
    }
}

/// Any node (and its subtree) from Pubd JSON: `pageFromJson` does not mind what it reads.
pub const nodeFromJson = pageFromJson;

// ------------------------------------------------------------------ instances in files

/// A page's copies of its components' content (`bases` in its file).
pub const Bases = std.json.ObjectMap;

/// The copies in a page file less its top-level nodes (the head a page read in pieces
/// starts from), built in `a`; null when it has none.
pub fn basesFromJson(a: std.mem.Allocator, head: []const u8) Error!?Bases {
    const root = try parse(a, head, null);
    const b = get(root, "bases") orelse return null;
    if (b != .object) return error.BadNode;
    return b.object;
}

/// A top-level node of a page read in pieces, its instances' content taken from the
/// page's `bases` (`basesFromJson` of the head).
pub fn childFromJson(gpa: std.mem.Allocator, a: std.mem.Allocator, json: []const u8, bases: ?*const Bases, options: Options) Error!m.Node {
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    const sa = scratch.allocator();
    var one = [1]Value{try parse(sa, json, options.problem)};
    if (bases) |b| try expandAll(sa, &one, b);
    var built = [1]m.Node{try node(sa, one[0])};
    try checkFinite(&.{
        .arena = undefined,
        .pages = &built,
    }, options.problem);
    return m.deepCopy(a, built[0]);
}

/// The instances among `nodes` (and below them) written as `changes` to a copy in
/// `bases` get their content back (SPEC.md "Instances in files").
fn expandAll(a: std.mem.Allocator, nodes: []Value, bases: *const Bases) Error!void {
    for (nodes) |*v| try expandNode(a, v, bases);
}

fn expandNode(a: std.mem.Allocator, v: *Value, bases: *const Bases) Error!void {
    if (v.* != .object) return error.BadNode;
    const o = &v.object;
    const ch = o.get("changes") orelse {
        if (o.get("children")) |list| if (list == .array) try expandAll(a, list.array.items, bases);
        return;
    };
    const comp = str(v.*, "component") orelse return error.BadNode;
    const base = bases.get(comp) orelse return error.BadNode;
    const id = str(v.*, "id") orelse return error.BadNode;
    if (base != .array or ch != .object) return error.BadNode;
    const pre = try prefixOf(a, id);
    var kids = try relocated(a, base.array.items, pre);
    try expandAll(a, kids.items, bases);
    if (ch.object.count() > 0) {
        var at: std.StringHashMapUnmanaged(*std.json.ObjectMap) = .empty;
        try index(a, &at, kids.items, pre.len);
        for (ch.object.keys(), ch.object.values()) |path, d| {
            if (d != .object) return error.BadNode;
            if (path.len == 0) {
                const list = d.object.get("children") orelse return error.BadNode;
                if (list != .array) return error.BadNode;
                kids = try relocated(a, list.array.items, pre);
                try expandAll(a, kids.items, bases);
                continue;
            }
            const t = at.get(path) orelse return error.BadNode;
            for (d.object.keys(), d.object.values()) |k, x| {
                if (std.mem.eql(u8, k, "children")) {
                    if (x != .array) return error.BadNode;
                    const list = try relocated(a, x.array.items, pre);
                    try expandAll(a, list.items, bases);
                    try t.put(a, k, .{
                        .array = list,
                    });
                } else if (x == .null) {
                    _ = t.orderedRemove(k);
                } else try t.put(a, k, x);
            }
        }
    }
    _ = o.orderedRemove("changes");
    try o.put(a, "children", .{
        .array = kids,
    });
}

/// What the ids of an instance's content start with: `I<instance id>;` (an instance
/// inside another one's content has an id starting with `I` already).
fn prefixOf(a: std.mem.Allocator, id: []const u8) ![]u8 {
    return if (std.mem.startsWith(u8, id, "I")) std.mem.concat(a, u8, &.{ id, ";" }) else std.mem.concat(a, u8, &.{ "I", id, ";" });
}

/// Copies of nodes written relative to their instance, ids under `pre` (their other
/// fields shared: they are replaced, never changed in place).
fn relocated(a: std.mem.Allocator, items: []const Value, pre: []const u8) Error!std.json.Array {
    var out = try std.json.Array.initCapacity(a, items.len);
    for (items) |x| {
        if (x != .object) return error.BadNode;
        const id = str(x, "id") orelse return error.BadNode;
        var o = try x.object.clone(a);
        try o.put(a, "id", .{
            .string = try std.mem.concat(a, u8, &.{ pre, id }),
        });
        if (x.object.get("children")) |c| if (c == .array) try o.put(a, "children", .{
            .array = try relocated(a, c.array.items, pre),
        });
        out.appendAssumeCapacity(.{
            .object = o,
        });
    }
    return out;
}

/// Each node of an instance's content by its path (its id less the prefix).
fn index(a: std.mem.Allocator, at: *std.StringHashMapUnmanaged(*std.json.ObjectMap), items: []Value, pre_len: usize) Error!void {
    for (items) |*x| {
        const id = str(x.*, "id") orelse return error.BadNode;
        if (id.len < pre_len) return error.BadNode;
        try at.put(a, id[pre_len..], &x.object);
        if (x.object.get("children")) |c| if (c == .array) try index(a, at, c.array.items, pre_len);
    }
}

/// A node from parsed Pubd JSON, built in `a`; its strings point into `v`.
pub fn nodeOf(a: std.mem.Allocator, v: Value) Error!m.Node {
    return node(a, v);
}

/// Parses JSON as Pubd reads it (`nan`/`inf` refused, saying where).
pub fn parseValue(a: std.mem.Allocator, json: []const u8) Error!Value {
    return parse(a, json, null);
}

fn parse(a: std.mem.Allocator, json: []const u8, problem: ?*Problem) Error!Value {
    var scanner: std.json.Scanner = .initCompleteInput(a, json);
    defer scanner.deinit();
    var diag: std.json.Diagnostics = .{};
    scanner.enableDiagnostics(&diag);
    return std.json.parseFromTokenSourceLeaky(Value, a, &scanner, .{
        .duplicate_field_behavior = .use_last,
    }) catch |err| {
        if (err == error.SyntaxError) if (bareWordAt(json, diag.getByteOffset())) |word| {
            if (isNotFiniteWord(word)) {
                if (problem) |p| p.set("line {d}, column {d}: `{s}` is not a number Pubd can hold (numbers must be finite)", .{ diag.getLine(), diag.getColumn(), word });
                return error.NotFinite;
            }
        };
        return err;
    };
}

/// A number too large for an f32 reads as infinite: refused.
fn checkFinite(doc: *const m.Document, problem: ?*Problem) Error!void {
    if (m.findNotFinite(doc)) |nf| {
        if (problem) |p| {
            var buf: [200]u8 = undefined;
            p.set("{s}", .{nf.describe(&buf)});
        }
        return error.NotFinite;
    }
}

/// The document as read, everything in `a` (pointing into the parsed JSON).
fn build(a: std.mem.Allocator, json: []const u8, problem: ?*Problem) Error!m.Document {
    var doc: m.Document = .{
        .arena = undefined,
    };
    const root = try parse(a, json, problem);
    const v = get(root, "pubd") orelse return error.NotPubd;
    if (v != .integer) return error.NotPubd;
    if (v.integer > version) return error.UnsupportedVersion;
    doc.name = str(root, "name") orelse "";

    var pages: std.ArrayList(m.Node) = .empty;
    var chunks: std.ArrayList(m.PageChunk) = .empty;
    for (arr(root, "pages")) |p| {
        try pages.append(a, try node(a, p));
        if (str(p, "src")) |src| {
            const fl = arr(p, "frames");
            const frames = try a.alloc(m.FrameInfo, fl.len);
            for (frames, fl) |*f, fv| f.* = .{
                .id = str(fv, "id") orelse "",
                .name = str(fv, "name") orelse "",
                .kind = enumField(m.Kind, fv, "type", .frame),
                .box = four(get(fv, "box")),
                .bounds = four(get(fv, "bounds")),
            };
            try chunks.append(a, .{
                .src = src,
                .frames = frames,
            });
        }
    }
    doc.pages = pages.items;
    // Page by page only when every page has its file.
    if (chunks.items.len == pages.items.len and chunks.items.len > 0) doc.chunks = chunks.items;
    var shared: std.ArrayList(m.Node) = .empty;
    for (arr(root, "shared")) |n| try shared.append(a, try node(a, n));
    doc.shared = shared.items;
    if (get(root, "components")) |cs| if (cs == .object) {
        var list: std.ArrayList(m.ComponentRef) = .empty;
        var it = cs.object.iterator();
        while (it.next()) |e| {
            var holder: m.Node = .{
                .id = "",
                .kind = .component,
            };
            try components(a, e.value_ptr.*, &holder);
            try list.append(a, .{
                .id = e.key_ptr.*,
                .name = str(e.value_ptr.*, "name") orelse "",
                .kind = enumField(m.Kind, e.value_ptr.*, "type", .component),
                .page = str(e.value_ptr.*, "page") orelse "",
                .set = str(e.value_ptr.*, "set") orelse "",
                .properties = holder.properties,
            });
        }
        doc.components = list.items;
    };
    var glyphs: std.ArrayList([]const u8) = .empty;
    for (arr(root, "glyphs")) |g| try glyphs.append(a, if (g == .string) g.string else "");
    doc.glyphs = glyphs.items;
    var fonts: std.ArrayList(m.FontRef) = .empty;
    for (arr(root, "fonts")) |f| try fonts.append(a, .{
        .family = str(f, "family") orelse continue,
        .style = str(f, "style") orelse "Regular",
        .weight = @intFromFloat(std.math.clamp(num(f, "weight") orelse 400, 1, 1000)),
        .italic = boolean(f, "italic") orelse false,
    });
    doc.fonts = fonts.items;
    try variables(a, root, &doc);

    if (get(root, "styles")) |styles| if (styles == .object) {
        var list: std.ArrayList(m.Style) = .empty;
        var it = styles.object.iterator();
        while (it.next()) |e| {
            const kind = enumOf(m.StyleKind, str(e.value_ptr.*, "type") orelse continue) orelse continue;
            try list.append(a, .{
                .id = e.key_ptr.*,
                .kind = kind,
                .name = str(e.value_ptr.*, "name") orelse "",
                .description = str(e.value_ptr.*, "description") orelse "",
                .value = if (get(e.value_ptr.*, "value")) |val| try jsonText(a, val) else null,
                .library = boolean(e.value_ptr.*, "library") orelse false,
                .key = str(e.value_ptr.*, "key") orelse "",
                .deleted = boolean(e.value_ptr.*, "deleted") orelse false,
            });
        }
        doc.styles = list.items;
    };

    if (get(root, "assets")) |assets| if (assets == .object) {
        var list: std.ArrayList(m.Asset) = .empty;
        var it = assets.object.iterator();
        while (it.next()) |e| try list.append(a, .{
            .hash = e.key_ptr.*,
            .type = str(e.value_ptr.*, "type") orelse "",
            .width = @intFromFloat(@max(0, num(e.value_ptr.*, "width") orelse 0)),
            .height = @intFromFloat(@max(0, num(e.value_ptr.*, "height") orelse 0)),
        });
        doc.assets = list.items;
    };
    try checkFinite(&doc, problem);
    return doc;
}

/// The run of letters (and a leading minus) around byte `at`: the word the JSON scanner
/// stopped in.
fn bareWordAt(json: []const u8, at: u64) ?[]const u8 {
    var i: usize = @intCast(@min(at, json.len));
    var j = i;
    while (i > 0 and (std.ascii.isAlphabetic(json[i - 1]) or json[i - 1] == '-')) i -= 1;
    while (j < json.len and std.ascii.isAlphabetic(json[j])) j += 1;
    return if (j > i) json[i..j] else null;
}

fn isNotFiniteWord(w: []const u8) bool {
    const word = if (w.len > 0 and w[0] == '-') w[1..] else w;
    for ([_][]const u8{ "nan", "inf", "infinity" }) |x| {
        if (std.ascii.eqlIgnoreCase(word, x)) return true;
    }
    return false;
}

fn jsonText(a: std.mem.Allocator, v: Value) ![]const u8 {
    return std.json.Stringify.valueAlloc(a, v, .{});
}

/// Pubd enum values use dashes where Zig uses underscores.
fn enumOf(comptime E: type, s: []const u8) ?E {
    var buf: [40]u8 = undefined;
    if (s.len > buf.len) return null;
    for (s, buf[0..s.len]) |c, *o| o.* = if (c == '-') '_' else c;
    return std.meta.stringToEnum(E, buf[0..s.len]);
}

fn enumField(comptime E: type, v: Value, key: []const u8, default: E) E {
    return enumOf(E, str(v, key) orelse return default) orelse default;
}

fn node(a: std.mem.Allocator, v: Value) Error!m.Node {
    const kind = enumOf(m.Kind, str(v, "type") orelse return error.BadNode) orelse return error.BadNode;
    // A page's instances written as changes to its copies get their content first.
    if (kind == .page) if (get(v, "bases")) |b| {
        if (b != .object) return error.BadNode;
        if (get(v, "children")) |list| if (list == .array) try expandAll(a, list.array.items, &b.object);
    };
    var n: m.Node = .{
        .id = str(v, "id") orelse return error.BadNode,
        .kind = kind,
        .name = str(v, "name") orelse "",
        .visible = boolean(v, "visible") orelse true,
        .locked = boolean(v, "locked") orelse false,
        .opacity = num(v, "opacity") orelse 1,
        .blend = enumField(m.Blend, v, "blend", .pass_through),
        .smoothing = num(v, "smoothing") orelse 0,
        .clip = boolean(v, "clip") orelse false,
        .component = str(v, "component"),
        .scale = num(v, "scale") orelse 1,
        .absolute = boolean(v, "absolute") orelse false,
    };
    if (get(v, "background")) |c| n.background = color(c);
    if (get(v, "edits")) |e| {
        if (e == .integer and e.integer > 0) n.edits = @intCast(e.integer);
    }
    if (get(v, "transform")) |t| n.transform = transformOf(t);
    if (get(v, "size")) |s| n.size = vec(s);
    n.fills = try paints(a, arr(v, "fills"));
    n.strokes = try paints(a, arr(v, "strokes"));
    if (get(v, "stroke")) |s| n.stroke = try stroke(a, s);
    n.effects = try effects(a, arr(v, "effects"));
    if (get(v, "styles")) |s| n.styles = .{
        .fill = str(s, "fill"),
        .stroke = str(s, "stroke"),
        .effect = str(s, "effect"),
        .text = str(s, "text"),
        .grid = str(s, "grid"),
    };
    if (get(v, "data")) |d| n.data = try jsonText(a, d);
    if (get(v, "radius")) |r| {
        if (numberOf(r)) |x| {
            n.radius = .{ x, x, x, x };
        } else if (r == .array and r.array.items.len == 4) {
            for (&n.radius, r.array.items) |*d, x| d.* = numberOf(x) orelse 0;
        }
    }
    if (get(v, "layout")) |l| n.layout = .{
        .mode = enumField(m.LayoutMode, l, "mode", .horizontal),
        .wrap = boolean(l, "wrap") orelse false,
        .gap = num(l, "gap") orelse 0,
        .cross_gap = num(l, "crossGap") orelse 0,
        .padding = four(get(l, "padding")),
        .main = enumField(m.MainAlign, l, "main", .start),
        .cross = enumField(m.CrossAlign, l, "cross", .start),
        .width = enumField(m.AxisSizing, l, "width", .fixed),
        .height = enumField(m.AxisSizing, l, "height", .fixed),
        .align_content = enumField(m.AlignContent, l, "alignContent", .auto),
        .strokes_included = boolean(l, "strokesIncluded") orelse false,
        .columns = try tracks(a, arr(l, "columns")),
        .rows = try tracks(a, arr(l, "rows")),
    };
    if (arr(v, "grids").len > 0) {
        var list: std.ArrayList(m.Grid) = .empty;
        for (arr(v, "grids")) |g| try list.append(a, .{
            .kind = enumField(m.GridKind, g, "type", .columns),
            .count = @intFromFloat(@max(0, num(g, "count") orelse 0)),
            .gutter = num(g, "gutter") orelse 0,
            .offset = num(g, "offset") orelse 0,
            .size = num(g, "size") orelse 0,
            .@"align" = enumField(m.GridAlign, g, "align", .stretch),
            .color = if (get(g, "color")) |c| color(c) else .{
                .r = 1,
                .a = 0.1,
            },
            .visible = boolean(g, "visible") orelse true,
            .vars = try bindings(a, g),
        });
        n.grids = list.items;
    }
    if (get(v, "constraints")) |c| n.constraints = .{
        .h = enumField(m.HConstraint, c, "h", .left),
        .v = enumField(m.VConstraint, c, "v", .top),
    };
    n.min_width = num(v, "minWidth");
    n.max_width = num(v, "maxWidth");
    n.min_height = num(v, "minHeight");
    n.max_height = num(v, "maxHeight");
    if (get(v, "cell")) |c| n.cell = .{
        .column = count(c, "column", 0),
        .row = count(c, "row", 0),
        .column_span = count(c, "columnSpan", 1),
        .row_span = count(c, "rowSpan", 1),
        .h = enumField(m.CellAlign, c, "h", .auto),
        .v = enumField(m.CellAlign, c, "v", .auto),
    };
    if (get(v, "sizing")) |z| n.sizing = .{
        .w = enumField(m.ChildSizing, z, "w", .fixed),
        .h = enumField(m.ChildSizing, z, "h", .fixed),
    };
    if (get(v, "arc")) |ad| n.arc = .{
        .start = num(ad, "start") orelse 0,
        .end = num(ad, "end") orelse std.math.tau,
        .inner = num(ad, "inner") orelse 0,
    };
    if (get(v, "network")) |net| n.network = try network(a, net);
    n.count = @intFromFloat(@max(0, num(v, "count") orelse 0));
    n.inner_scale = num(v, "innerScale") orelse 0;
    n.boolean_op = enumField(m.BooleanOp, v, "op", .@"union");
    const geo = arr(v, "geometry");
    if (geo.len > 0) {
        const out = try a.alloc(m.GeometryPath, geo.len);
        for (out, geo) |*o, g| o.* = .{
            .d = str(g, "d") orelse "",
            .winding = enumField(m.Winding, g, "winding", .nonzero),
            .fills = if (get(g, "fills")) |fs| (if (fs == .array) try paints(a, fs.array.items) else null) else null,
        };
        n.geometry = out;
    }
    if (str(v, "mask")) |mt| n.mask = enumOf(m.MaskType, mt);
    n.reverse_z = boolean(v, "reverseZ") orelse false;
    if (get(v, "repeat")) |r| n.repeat = .{
        .kind = enumField(m.RepeatKind, r, "type", .linear),
        .count = @intFromFloat(@max(1, num(r, "count") orelse 1)),
        .offset = num(r, "offset") orelse 0,
        .vertical = boolean(r, "vertical") orelse false,
    };
    if (kind == .text) n.text = try text(a, v);
    try components(a, v, &n);

    var children: std.ArrayList(m.Node) = .empty;
    for (arr(v, "children")) |c| try children.append(a, try node(a, c));
    n.children = children.items;
    return n;
}

/// Component properties, bindings, property values and overrides (draft 1).
fn components(a: std.mem.Allocator, v: Value, n: *m.Node) !void {
    const defs = arr(v, "properties");
    if (defs.len > 0) {
        var list: std.ArrayList(m.PropDef) = .empty;
        for (defs) |d| {
            const opts = arr(d, "options");
            const options = try a.alloc([]const u8, opts.len);
            var k: usize = 0;
            for (opts) |o| if (o == .string) {
                options[k] = o.string;
                k += 1;
            };
            try list.append(a, .{
                .id = str(d, "id") orelse continue,
                .name = str(d, "name") orelse "",
                .kind = enumField(m.PropKind, d, "type", .text),
                .default = if (get(d, "default")) |x| try jsonText(a, x) else "null",
                .options = options[0..k],
            });
        }
        n.properties = list.items;
    }
    if (get(v, "bind")) |b| n.bind = .{
        .visible = str(b, "visible"),
        .text = str(b, "text"),
        .component = str(b, "component"),
    };
    if (get(v, "props")) |p| if (p == .object) {
        var list: std.ArrayList(m.PropValue) = .empty;
        var it = p.object.iterator();
        while (it.next()) |e| try list.append(a, .{
            .id = e.key_ptr.*,
            .value = try jsonText(a, e.value_ptr.*),
        });
        n.props = list.items;
    };
    if (get(v, "overrides")) |o| if (o == .object) {
        var list: std.ArrayList(m.Override) = .empty;
        var it = o.object.iterator();
        while (it.next()) |e| {
            const ks = if (e.value_ptr.* == .array) e.value_ptr.array.items else &[_]Value{};
            const keys = try a.alloc([]const u8, ks.len);
            var k: usize = 0;
            for (ks) |x| if (x == .string) {
                keys[k] = x.string;
                k += 1;
            };
            try list.append(a, .{
                .path = e.key_ptr.*,
                .keys = keys[0..k],
            });
        }
        n.overrides = list.items;
    };
    n.vars = try bindings(a, v);
    if (get(v, "modes")) |o| if (o == .object) {
        var list: std.ArrayList(m.ModeChoice) = .empty;
        var it = o.object.iterator();
        while (it.next()) |e| if (e.value_ptr.* == .string) try list.append(a, .{
            .collection = e.key_ptr.*,
            .mode = e.value_ptr.string,
        });
        n.modes = list.items;
    };
}

/// An object's `vars` (`{ key: variable }`): the fields that follow variables.
fn bindings(a: std.mem.Allocator, v: Value) ![]m.VarBinding {
    const o = get(v, "vars") orelse return &.{};
    if (o != .object) return &.{};
    var list: std.ArrayList(m.VarBinding) = .empty;
    var it = o.object.iterator();
    while (it.next()) |e| if (e.value_ptr.* == .string) try list.append(a, .{
        .key = e.key_ptr.*,
        .variable = e.value_ptr.string,
    });
    return list.items;
}

/// The variable collections and variables of `document.json` (draft 2).
fn variables(a: std.mem.Allocator, root: Value, doc: *m.Document) !void {
    if (get(root, "collections")) |cs| if (cs == .object) {
        var list: std.ArrayList(m.Collection) = .empty;
        var it = cs.object.iterator();
        while (it.next()) |e| try list.append(a, try collectionOf(a, e.key_ptr.*, e.value_ptr.*));
        doc.collections = list.items;
    };
    if (get(root, "variables")) |vs| if (vs == .object) {
        var list: std.ArrayList(m.Variable) = .empty;
        var it = vs.object.iterator();
        while (it.next()) |e| try list.append(a, try variableOf(a, e.key_ptr.*, e.value_ptr.*));
        doc.variables = list.items;
    };
}

fn valuesOf(a: std.mem.Allocator, v: ?Value) ![]m.VariableValue {
    var values: std.ArrayList(m.VariableValue) = .empty;
    if (v) |vals| if (vals == .object) {
        var vi = vals.object.iterator();
        while (vi.next()) |x| try values.append(a, .{
            .mode = x.key_ptr.*,
            .value = try jsonText(a, x.value_ptr.*),
        });
    };
    return values.items;
}

/// A collection from its JSON (`id` its key in `collections`, or its own `id`).
pub fn collectionOf(a: std.mem.Allocator, id: []const u8, v: Value) !m.Collection {
    var modes: std.ArrayList(m.VariableMode) = .empty;
    for (arr(v, "modes")) |md| try modes.append(a, .{
        .id = str(md, "id") orelse continue,
        .name = str(md, "name") orelse "",
        .parent = str(md, "parent"),
    });
    var overrides: std.ArrayList(m.VariableOverride) = .empty;
    if (get(v, "overrides")) |ov| if (ov == .object) {
        var it = ov.object.iterator();
        while (it.next()) |e| try overrides.append(a, .{
            .variable = e.key_ptr.*,
            .values = try valuesOf(a, e.value_ptr.*),
        });
    };
    return .{
        .id = id,
        .name = str(v, "name") orelse "",
        .modes = modes.items,
        .library = boolean(v, "library") orelse false,
        .key = str(v, "key") orelse "",
        .hidden = boolean(v, "hidden") orelse false,
        .parent = str(v, "parent"),
        .overrides = overrides.items,
        .deleted = boolean(v, "deleted") orelse false,
    };
}

/// A variable from its JSON (`id` its key in `variables`, or its own `id`).
pub fn variableOf(a: std.mem.Allocator, id: []const u8, v: Value) !m.Variable {
    var scopes: std.ArrayList([]const u8) = .empty;
    for (arr(v, "scopes")) |sc| if (sc == .string) try scopes.append(a, sc.string);
    const code = get(v, "code");
    return .{
        .id = id,
        .name = str(v, "name") orelse "",
        .collection = str(v, "collection") orelse "",
        .type = enumField(m.VariableType, v, "type", .color),
        .description = str(v, "description") orelse "",
        .values = try valuesOf(a, get(v, "values")),
        .scopes = scopes.items,
        .key = str(v, "key") orelse "",
        .hidden = boolean(v, "hidden") orelse false,
        .deleted = boolean(v, "deleted") orelse false,
        .code = if (code) |c| .{
            .web = str(c, "web") orelse "",
            .ios = str(c, "ios") orelse "",
            .android = str(c, "android") orelse "",
        } else .{},
    };
}

fn paints(a: std.mem.Allocator, list: []const Value) ![]m.Paint {
    var out: std.ArrayList(m.Paint) = .empty;
    for (list) |p| {
        const kind = enumField(m.PaintKind, p, "type", .solid);
        var paint: m.Paint = .{
            .kind = kind,
            .visible = boolean(p, "visible") orelse true,
            .opacity = num(p, "opacity") orelse 1,
            .blend = enumField(m.Blend, p, "blend", .normal),
            .variable = str(p, "var"),
            .vars = try bindings(a, p),
        };
        switch (kind) {
            .solid => paint.color = if (get(p, "color")) |c| color(c) else .{},
            .linear, .radial, .angular, .diamond => {
                var stops: std.ArrayList(m.Stop) = .empty;
                for (arr(p, "stops")) |s| try stops.append(a, .{
                    .at = num(s, "at") orelse 0,
                    .color = if (get(s, "color")) |c| color(c) else .{},
                    .variable = str(s, "var"),
                });
                paint.stops = stops.items;
                const hs = arr(p, "handles");
                for (hs[0..@min(3, hs.len)], 0..) |h, i| paint.handles[i] = vec(h);
            },
            .image => {
                paint.asset = str(p, "asset") orelse "";
                paint.scale = enumField(m.ScaleMode, p, "scale", .fill);
                if (get(p, "transform")) |t| paint.image_transform = transformOf(t);
                paint.tile = num(p, "tile") orelse 1;
            },
            .pattern => {
                paint.source = str(p, "source") orelse "";
                paint.tile_type = enumField(m.TileType, p, "tiles", .rectangular);
                paint.tile = num(p, "scale") orelse 1;
                if (get(p, "spacing")) |sp| paint.spacing = vec(sp);
                const al = arr(p, "align");
                if (al.len == 2) {
                    if (al[0] == .string) paint.h_align = enumOf(m.TileAlign, al[0].string) orelse .start;
                    if (al[1] == .string) paint.v_align = enumOf(m.TileAlign, al[1].string) orelse .start;
                }
            },
        }
        try out.append(a, paint);
    }
    return out.items;
}

fn stroke(a: std.mem.Allocator, v: Value) !m.Stroke {
    var s: m.Stroke = .{
        .weight = num(v, "weight") orelse 1,
        .@"align" = if (str(v, "align")) |al| enumOf(m.StrokeAlign, al) else null,
        .cap = enumField(m.Cap, v, "cap", .none),
        .join = enumField(m.Join, v, "join", .miter),
        .miter = num(v, "miter") orelse 4,
    };
    const ds = arr(v, "dashes");
    if (ds.len > 0) {
        const d = try a.alloc(f32, ds.len);
        for (d, ds) |*o, x| o.* = numberOf(x) orelse 0;
        s.dashes = d;
    }
    if (get(v, "sides")) |sd| s.sides = four(sd);
    const ol = arr(v, "outline");
    if (ol.len > 0) {
        const out = try a.alloc(m.OutlinePath, ol.len);
        for (out, ol) |*o, x| o.* = .{
            .d = str(x, "d") orelse "",
            .winding = enumField(m.Winding, x, "winding", .nonzero),
        };
        s.outline = out;
    }
    const ws = arr(v, "widths");
    if (ws.len > 0) {
        const out = try a.alloc(m.WidthPoint, ws.len);
        for (out, ws) |*o, x| o.* = .{
            .segment = @intFromFloat(std.math.clamp(num(x, "segment") orelse 0, 0, 1e9)),
            .at = num(x, "at") orelse 0,
            .ascent = num(x, "ascent") orelse 0.5,
            .descent = num(x, "descent") orelse 0.5,
        };
        s.widths = out;
    }
    if (get(v, "brush")) |b| {
        var br: m.Brush = .{
            .name = str(b, "name") orelse "",
            .kind = enumField(m.BrushKind, b, "type", .stretch),
            .size = if (get(b, "size")) |sz| vec(sz) else .{},
            .reverse = boolean(b, "reverse") orelse false,
            .scatter = if (get(b, "scatter")) |sc| scatterOf(sc) else null,
            .adjust = if (get(b, "adjust")) |sc| scatterOf(sc) else null,
        };
        const geo = arr(b, "geometry");
        if (geo.len > 0) {
            const out = try a.alloc(m.GeometryPath, geo.len);
            for (out, geo) |*o, g| o.* = .{
                .d = str(g, "d") orelse "",
                .winding = enumField(m.Winding, g, "winding", .nonzero),
            };
            br.geometry = out;
        }
        const stamps = arr(b, "stamps");
        if (stamps.len > 0) {
            const out = try a.alloc(geom.Affine, stamps.len);
            for (out, stamps) |*o, t| o.* = transformOf(t);
            br.stamps = out;
        }
        s.brush = br;
    }
    if (get(v, "dynamic")) |d| s.dynamic = .{
        .frequency = num(d, "frequency") orelse 0,
        .wiggle = num(d, "wiggle") orelse 0,
        .smoothen = num(d, "smoothen") orelse 0,
    };
    return s;
}

fn scatterOf(v: Value) m.Scatter {
    return .{
        .gap = num(v, "gap") orelse 0,
        .wiggle = num(v, "wiggle") orelse 0,
        .angle_jitter = num(v, "angleJitter") orelse 0,
        .rotation = num(v, "rotation") orelse 0,
        .size_jitter = num(v, "sizeJitter") orelse 0,
    };
}

fn effects(a: std.mem.Allocator, list: []const Value) ![]m.Effect {
    var out: std.ArrayList(m.Effect) = .empty;
    for (list) |e| {
        const kind = enumOf(m.EffectKind, str(e, "type") orelse continue) orelse continue;
        try out.append(a, .{
            .kind = kind,
            .visible = boolean(e, "visible") orelse true,
            .color = if (get(e, "color")) |c| color(c) else .{
                .a = 0.25,
            },
            .offset = if (get(e, "offset")) |o| vec(o) else .{},
            .radius = num(e, "radius") orelse 4,
            .spread = num(e, "spread") orelse 0,
            .behind = boolean(e, "behind") orelse false,
            .blend = enumField(m.Blend, e, "blend", .normal),
            .progressive = if (get(e, "progressive")) |pg| .{
                .start = if (get(pg, "start")) |o| vec(o) else .{},
                .end = if (get(pg, "end")) |o| vec(o) else .{
                    .y = 1,
                },
                .start_radius = num(pg, "startRadius") orelse 0,
            } else null,
            .grain = if (get(e, "grain")) |g| vec(g) else .{
                .x = 2,
                .y = 2,
            },
            .noise = enumField(m.NoiseType, e, "noise", .monotone),
            .density = num(e, "density") orelse 0.5,
            .secondary = if (get(e, "secondary")) |c| color(c) else .{},
            .opacity = num(e, "opacity") orelse 1,
            .clip = boolean(e, "clip") orelse true,
            .seed = if (get(e, "seed")) |x| (if (x == .integer) @intCast(std.math.clamp(x.integer, 0, std.math.maxInt(u32))) else 0) else 0,
            .vars = try bindings(a, e),
        });
    }
    return out.items;
}

fn network(a: std.mem.Allocator, v: Value) !m.Network {
    var verts: std.ArrayList(geom.Vec2) = .empty;
    for (arr(v, "vertices")) |p| try verts.append(a, vec(p));
    var segs: std.ArrayList(m.Segment) = .empty;
    for (arr(v, "segments")) |s| try segs.append(a, .{
        .from = @intFromFloat(@max(0, num(s, "from") orelse 0)),
        .to = @intFromFloat(@max(0, num(s, "to") orelse 0)),
        .t0 = if (get(s, "t0")) |t| vec(t) else .{},
        .t1 = if (get(s, "t1")) |t| vec(t) else .{},
    });
    var regions: std.ArrayList(m.Region) = .empty;
    for (arr(v, "regions")) |r| {
        var loops: std.ArrayList([]u32) = .empty;
        for (arr(r, "loops")) |l| {
            var ids: std.ArrayList(u32) = .empty;
            if (l == .array) for (l.array.items) |i| try ids.append(a, @intFromFloat(@max(0, numberOf(i) orelse 0)));
            try loops.append(a, ids.items);
        }
        try regions.append(a, .{
            .winding = enumField(m.Winding, r, "winding", .nonzero),
            .loops = loops.items,
        });
    }
    return .{
        .vertices = verts.items,
        .segments = segs.items,
        .regions = regions.items,
    };
}

fn text(a: std.mem.Allocator, v: Value) !m.Text {
    var t: m.Text = .{
        .text = str(v, "text") orelse "",
        .style = if (get(v, "style")) |s| try textStyle(a, s) else .{},
        .resize = enumField(m.TextResize, v, "resize", .fixed),
        .@"align" = enumField(m.TextAlign, v, "align", .left),
        .valign = enumField(m.TextVAlign, v, "valign", .top),
        .truncation = enumField(m.TextTruncation, v, "truncation", .none),
        .wrap = enumField(m.TextWrap, v, "wrap", .auto),
        .leading_trim = enumField(m.LeadingTrim, v, "leadingTrim", .none),
        .hanging_punctuation = boolean(v, "hangingPunctuation") orelse false,
        .hanging_list = boolean(v, "hangingList") orelse false,
    };
    if (num(v, "maxLines")) |ml| if (ml >= 1) {
        t.max_lines = @intFromFloat(@min(ml, 1e6));
    };
    var lists: std.ArrayList(m.ParagraphList) = .empty;
    for (arr(v, "lists")) |l| try lists.append(a, .{
        .type = enumField(m.ListType, l, "type", .none),
        .indent = @intFromFloat(std.math.clamp(num(l, "indent") orelse 0, 0, 255)),
    });
    t.lists = lists.items;
    if (get(v, "pathStart")) |ps| t.path_start = .{
        .segment = @intFromFloat(std.math.clamp(num(ps, "segment") orelse 0, 0, 1e6)),
        .position = num(ps, "position") orelse 0,
    };
    const gl = arr(v, "glyphs");
    if (gl.len > 0) {
        const out = try a.alloc(m.TextGlyph, gl.len);
        var n: usize = 0;
        for (gl) |g| {
            if (g != .array or g.array.items.len < 5) continue;
            const x = g.array.items;
            out[n] = .{
                .outline = @intFromFloat(std.math.clamp(numberOf(x[0]) orelse 0, 0, 4e9)),
                .x = numberOf(x[1]) orelse 0,
                .y = numberOf(x[2]) orelse 0,
                .size = numberOf(x[3]) orelse 0,
                .char = @intFromFloat(std.math.clamp(numberOf(x[4]) orelse 0, 0, 4e9)),
                .rotation = if (x.len > 5) numberOf(x[5]) orelse 0 else 0,
            };
            n += 1;
        }
        t.glyphs = out[0..n];
    }
    const gr = arr(v, "glyphRects");
    if (gr.len > 0) {
        const out = try a.alloc(m.TextRect, gr.len);
        var n: usize = 0;
        for (gr) |g| {
            if (g != .array or g.array.items.len < 5) continue;
            const x = g.array.items;
            out[n] = .{
                .rect = .{ numberOf(x[0]) orelse 0, numberOf(x[1]) orelse 0, numberOf(x[2]) orelse 0, numberOf(x[3]) orelse 0 },
                .char = @intFromFloat(std.math.clamp(numberOf(x[4]) orelse 0, 0, 4e9)),
            };
            n += 1;
        }
        t.glyph_rects = out[0..n];
    }
    var runs: std.ArrayList(m.Run) = .empty;
    for (arr(v, "runs")) |r| try runs.append(a, .{
        .from = @intFromFloat(@max(0, num(r, "from") orelse 0)),
        .to = @intFromFloat(@max(0, num(r, "to") orelse 0)),
        .style = if (get(r, "style")) |s| try textStyle(a, s) else .{},
        .fills = if (get(r, "fills")) |fs| (if (fs == .array) try paints(a, fs.array.items) else null) else null,
    });
    t.runs = runs.items;
    t.skip_ink = boolean(v, "skipInk") orelse true;
    return t;
}

fn textStyle(a: std.mem.Allocator, v: Value) !m.TextStyle {
    var s: m.TextStyle = .{
        .vars = try bindings(a, v),
        .family = str(v, "family"),
        .italic = boolean(v, "italic"),
        .font_style = str(v, "fontStyle"),
        .size = num(v, "size"),
        .paragraph_spacing = num(v, "paragraphSpacing"),
        .paragraph_indent = num(v, "paragraphIndent"),
        .case = if (str(v, "case")) |c| enumOf(m.TextCase, c) else null,
        .decoration = if (str(v, "decoration")) |d| enumOf(m.Decoration, d) else null,
        .decoration_style = if (str(v, "decorationStyle")) |d| enumOf(m.DecorationStyle, d) else null,
    };
    if (num(v, "weight")) |w| s.weight = @intFromFloat(std.math.clamp(w, 1, 1000));
    if (get(v, "lineHeight")) |lh| {
        if (lh == .string) {
            s.line_height = .auto;
        } else if (num(lh, "px")) |px| {
            s.line_height = .{
                .px = px,
            };
        } else if (num(lh, "percent")) |p| {
            s.line_height = .{
                .percent = p,
            };
        }
    }
    if (get(v, "letterSpacing")) |ls| {
        if (numberOf(ls)) |px| {
            s.letter_spacing = .{
                .px = px,
            };
        } else if (num(ls, "percent")) |p| {
            s.letter_spacing = .{
                .percent = p,
            };
        }
    }
    return s;
}

fn vec(v: Value) geom.Vec2 {
    if (v != .array or v.array.items.len < 2) return .{};
    return .{
        .x = numberOf(v.array.items[0]) orelse 0,
        .y = numberOf(v.array.items[1]) orelse 0,
    };
}

/// A whole number field (negative and missing read as `default`).
fn count(v: Value, key: []const u8, default: u32) u32 {
    const x = num(v, key) orelse return default;
    return if (x >= 0 and x < 1e9) @intFromFloat(x) else default;
}

/// Grid tracks: `{ "type": "fixed" | "flex" | "hug", "value": n }`.
fn tracks(a: std.mem.Allocator, list: []const Value) ![]m.Track {
    if (list.len == 0) return &.{};
    const out = try a.alloc(m.Track, list.len);
    for (out, list) |*o, t| o.* = .{
        .kind = enumField(m.TrackKind, t, "type", .flex),
        .value = num(t, "value") orelse 1,
    };
    return out;
}

fn four(v: ?Value) [4]f32 {
    var out: [4]f32 = .{ 0, 0, 0, 0 };
    const x = v orelse return out;
    if (x != .array or x.array.items.len != 4) return out;
    for (&out, x.array.items) |*o, i| o.* = numberOf(i) orelse 0;
    return out;
}

fn transformOf(v: Value) geom.Affine {
    if (v != .array or v.array.items.len != 6) return .identity;
    var t: [6]f32 = undefined;
    for (&t, v.array.items) |*o, x| o.* = numberOf(x) orelse 0;
    return .{
        .a = t[0],
        .b = t[1],
        .c = t[2],
        .d = t[3],
        .e = t[4],
        .f = t[5],
    };
}

/// `#rgb`, `#rrggbb`, `#rrggbbaa`, or `[r, g, b]` / `[r, g, b, a]` of numbers 0..1 kept
/// at full precision.
pub fn color(v: Value) m.Color {
    if (v == .array) {
        const xs = v.array.items;
        if (xs.len != 3 and xs.len != 4) return .{};
        return .{
            .r = numberOf(xs[0]) orelse 0,
            .g = numberOf(xs[1]) orelse 0,
            .b = numberOf(xs[2]) orelse 0,
            .a = if (xs.len == 4) numberOf(xs[3]) orelse 1 else 1,
        };
    }
    if (v != .string) return .{};
    const s = v.string;
    if (s.len == 0 or s[0] != '#') return .{};
    const h = s[1..];
    var c: [4]u8 = .{ 0, 0, 0, 255 };
    if (h.len == 3) {
        for (0..3) |i| {
            const d = std.fmt.charToDigit(h[i], 16) catch 0;
            c[i] = d * 17;
        }
    } else if (h.len == 6 or h.len == 8) {
        for (0..h.len / 2) |i| c[i] = std.fmt.parseInt(u8, h[i * 2 ..][0..2], 16) catch 0;
    }
    return .{
        .r = @as(f32, @floatFromInt(c[0])) / 255,
        .g = @as(f32, @floatFromInt(c[1])) / 255,
        .b = @as(f32, @floatFromInt(c[2])) / 255,
        .a = @as(f32, @floatFromInt(c[3])) / 255,
    };
}

test "colours read from hex and from arrays" {
    const gpa = std.testing.allocator;
    const hex = try std.json.parseFromSlice(Value, gpa, "\"#ff800040\"", .{});
    defer hex.deinit();
    const a = color(hex.value);
    try std.testing.expectEqual(@as(f32, 1), a.r);
    try std.testing.expectEqual(@as(f32, 128.0 / 255.0), a.g);
    try std.testing.expectEqual(@as(f32, 0), a.b);
    try std.testing.expectEqual(@as(f32, 64.0 / 255.0), a.a);
    const list = try std.json.parseFromSlice(Value, gpa, "[0.76, 0.7, 1]", .{});
    defer list.deinit();
    const b = color(list.value);
    try std.testing.expectEqual(@as(f32, 0.7), b.g);
    try std.testing.expectEqual(@as(f32, 1), b.b);
    try std.testing.expectEqual(@as(f32, 1), b.a);
}

test "round trip through Pubd JSON" {
    const figma = @import("../import/figma.zig");
    const write = @import("write.zig");
    const gpa = std.testing.allocator;
    const json =
        \\{"name":"T","document":{"id":"0:0","type":"DOCUMENT","children":[{"id":"0:1","type":"CANVAS","name":"Page",
        \\"children":[{"id":"1:2","type":"FRAME","name":"F","relativeTransform":[[1,0,10],[0,1,20]],"size":{"x":100,"y":50},
        \\"clipsContent":true,"rectangleCornerRadii":[1,2,3,4],"layoutMode":"VERTICAL","itemSpacing":-176,
        \\"fills":[{"type":"GRADIENT_LINEAR","gradientHandlePositions":[{"x":0,"y":0},{"x":1,"y":1},{"x":0,"y":1}],
        \\"gradientStops":[{"position":0,"color":{"r":1,"g":0,"b":0,"a":1}},{"position":1,"color":{"r":0,"g":0,"b":1,"a":0.5}}]}],
        \\"effects":[{"type":"DROP_SHADOW","color":{"r":0,"g":0,"b":0,"a":0.25},"offset":{"x":0,"y":4},"radius":16,"spread":-4,"showShadowBehindNode":true}],
        \\"children":[{"id":"1:3","type":"TEXT","characters":"Hi there","style":{"fontFamily":"Work Sans","fontWeight":700,"fontSize":24,"lineHeightUnit":"INTRINSIC_%","textCase":"SMALL_CAPS_FORCED"},
        \\"characterStyleOverrides":[0,0,0,1,1],"styleOverrideTable":{"1":{"fontWeight":400}},"relativeTransform":[[1,0,0],[0,1,0]],"size":{"x":10,"y":10}}]}]}]}}
    ;
    var r = try figma.import(gpa, json);
    defer r.doc.deinit();
    const out = try write.toJson(gpa, &r.doc);
    defer gpa.free(out);
    var back = try fromJson(gpa, out, .{});
    defer back.deinit();
    const f = back.pages[0].children[0];
    try std.testing.expectEqual(@as(f32, 4), f.radius[3]);
    try std.testing.expectEqual(@as(f32, -176), f.layout.?.gap);
    try std.testing.expectEqual(m.PaintKind.linear, f.fills[0].kind);
    try std.testing.expectEqual(@as(f32, 0.5), f.fills[0].stops[1].color.a);
    try std.testing.expectEqual(@as(f32, -4), f.effects[0].spread);
    try std.testing.expect(f.effects[0].behind);
    const t = f.children[0].text.?;
    try std.testing.expectEqualStrings("Hi there", t.text);
    try std.testing.expectEqual(m.TextCase.small_caps_forced, t.style.case.?);
    try std.testing.expectEqual(@as(u32, 3), t.runs[0].from);
    try std.testing.expectEqual(@as(u16, 400), t.runs[0].style.weight.?);
    // Writing again gives the same bytes.
    const again = try write.toJson(gpa, &back);
    defer gpa.free(again);
    try std.testing.expectEqualStrings(out, again);
}

test "layout fields round trip: grids, cells, limits, distributions" {
    const figma = @import("../import/figma.zig");
    const write = @import("write.zig");
    const gpa = std.testing.allocator;
    const json =
        \\{"name":"T","document":{"id":"0:0","type":"DOCUMENT","children":[{"id":"0:1","type":"CANVAS","name":"Page",
        \\"children":[{"id":"1:2","type":"FRAME","layoutMode":"GRID","gridColumnsSizing":"repeat(2,minmax(0,1fr)) 84px",
        \\"gridRowsSizing":"fit-content(100%)","gridColumnGap":12,"gridRowGap":8,"strokesIncludedInLayout":true,
        \\"size":{"x":300,"y":100},"children":[{"id":"1:3","type":"RECTANGLE","gridColumnAnchorIndex":1,
        \\"gridRowAnchorIndex":0,"gridColumnSpan":2,"gridChildHorizontalAlign":"CENTER","minWidth":10,"maxHeight":50}]},
        \\{"id":"1:4","type":"FRAME","layoutMode":"HORIZONTAL","layoutWrap":"WRAP","primaryAxisAlignItems":"SPACE_EVENLY",
        \\"counterAxisAlignContent":"SPACE_BETWEEN","counterAxisSpacing":6},
        \\{"id":"1:5","type":"INSTANCE","componentId":"1:4","uniformScaleFactor":0.5}]}]}}
    ;
    var r = try figma.import(gpa, json);
    defer r.doc.deinit();
    const out = try write.toJson(gpa, &r.doc);
    defer gpa.free(out);
    var back = try fromJson(gpa, out, .{});
    defer back.deinit();
    const g = back.pages[0].children[0];
    const l = g.layout.?;
    try std.testing.expectEqual(m.LayoutMode.grid, l.mode);
    try std.testing.expectEqual(@as(usize, 3), l.columns.len);
    try std.testing.expectEqual(m.TrackKind.fixed, l.columns[2].kind);
    try std.testing.expectEqual(@as(f32, 84), l.columns[2].value);
    try std.testing.expectEqual(m.TrackKind.hug, l.rows[0].kind);
    try std.testing.expectEqual(@as(f32, 12), l.gap);
    try std.testing.expectEqual(@as(f32, 8), l.cross_gap);
    try std.testing.expect(l.strokes_included);
    const c = g.children[0];
    try std.testing.expectEqual(@as(u32, 1), c.cell.?.column);
    try std.testing.expectEqual(@as(u32, 2), c.cell.?.column_span);
    try std.testing.expectEqual(m.CellAlign.center, c.cell.?.h);
    try std.testing.expectEqual(@as(f32, 10), c.min_width.?);
    try std.testing.expectEqual(@as(f32, 50), c.max_height.?);
    try std.testing.expect(c.max_width == null);
    const w = back.pages[0].children[1].layout.?;
    try std.testing.expectEqual(m.MainAlign.space_evenly, w.main);
    try std.testing.expectEqual(m.AlignContent.space_between, w.align_content);
    try std.testing.expect(w.wrap);
    try std.testing.expectEqual(@as(f32, 0.5), back.pages[0].children[2].scale);
    const again = try write.toJson(gpa, &back);
    defer gpa.free(again);
    try std.testing.expectEqualStrings(out, again);
}

test "numbers that are not finite are refused, saying where" {
    const gpa = std.testing.allocator;
    var p: Problem = .{};
    const bare =
        \\{"pubd": 0, "pages": [{"id": "0:1", "type": "page", "children": [
        \\  {"id": "4:103", "type": "group", "size": [nan, nan]}]}]}
    ;
    try std.testing.expectError(error.NotFinite, fromJson(gpa, bare, .{
        .problem = &p,
    }));
    try std.testing.expect(std.mem.indexOf(u8, p.message(), "line 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, p.message(), "`nan`") != null);
    const huge =
        \\{"pubd": 0, "pages": [{"id": "0:1", "type": "page", "children": [
        \\  {"id": "4:103", "type": "group", "size": [1e39, 2]}]}]}
    ;
    try std.testing.expectError(error.NotFinite, fromJson(gpa, huge, .{
        .problem = &p,
    }));
    try std.testing.expectEqualStrings("node 4:103: size.x is not a finite number", p.message());
    // Other broken JSON stays a syntax error.
    try std.testing.expectError(error.SyntaxError, fromJson(gpa, "{\"pubd\": 0, \"pages\": [}", .{}));
}
