//! A node's properties by their Pubd keys (`pubd/SPEC.md`): the values of some keys as
//! JSON, and keys set from JSON, leaving the rest of the node as it is. Every edit of a
//! property goes through here, so one change can name any field the format has.

const std = @import("std");
const m = @import("../pubd/model.zig");
const read = @import("../pubd/read.zig");
const write = @import("../pubd/write.zig");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;

/// A Pubd key on a node and the model fields it holds.
pub const Key = struct {
    /// The key in Pubd JSON.
    name: []const u8,
    /// The fields of `m.Node` it holds (of `m.Text` when `text`).
    fields: []const []const u8,
    text: bool = false,
    /// Changing it may move or resize something: auto layout runs after.
    layout: bool = true,
    /// What an instance may set itself (an override, `pubd/SPEC.md` "Components").
    override: bool = true,
    /// Changing it can change pixels (otherwise nothing is redrawn).
    visual: bool = true,
};

/// Every key a node has, but `id` and `children`. `type` changes only between kinds that
/// hold the same fields (the editor checks).
pub const keys = [_]Key{
    .{
        .name = "type",
        .fields = &.{"kind"},
        .override = false,
    },
    .{
        .name = "name",
        .fields = &.{"name"},
        .layout = false,
        .visual = false,
    },
    .{
        .name = "visible",
        .fields = &.{"visible"},
    },
    .{
        .name = "locked",
        .fields = &.{"locked"},
        .layout = false,
        .visual = false,
    },
    .{
        .name = "transform",
        .fields = &.{"transform"},
    },
    .{
        .name = "size",
        .fields = &.{"size"},
    },
    .{
        .name = "opacity",
        .fields = &.{"opacity"},
        .layout = false,
    },
    .{
        .name = "blend",
        .fields = &.{"blend"},
        .layout = false,
    },
    .{
        .name = "fills",
        .fields = &.{"fills"},
        .layout = false,
    },
    .{
        .name = "strokes",
        .fields = &.{"strokes"},
    },
    .{
        .name = "stroke",
        .fields = &.{"stroke"},
    },
    .{
        .name = "effects",
        .fields = &.{"effects"},
        .layout = false,
    },
    .{
        .name = "styles",
        .fields = &.{"styles"},
        .layout = false,
        .visual = false,
    },
    .{
        .name = "data",
        .fields = &.{"data"},
        .layout = false,
        .visual = false,
    },
    .{
        .name = "background",
        .fields = &.{"background"},
        .layout = false,
    },
    .{
        .name = "radius",
        .fields = &.{"radius"},
        .layout = false,
    },
    .{
        .name = "smoothing",
        .fields = &.{"smoothing"},
        .layout = false,
    },
    .{
        .name = "clip",
        .fields = &.{"clip"},
        .layout = false,
    },
    .{
        .name = "layout",
        .fields = &.{"layout"},
    },
    .{
        .name = "grids",
        .fields = &.{"grids"},
        .layout = false,
    },
    .{
        .name = "component",
        .fields = &.{"component"},
        .visual = false,
    },
    .{
        .name = "scale",
        .fields = &.{"scale"},
    },
    .{
        .name = "constraints",
        .fields = &.{"constraints"},
        .layout = false,
    },
    .{
        .name = "sizing",
        .fields = &.{"sizing"},
    },
    .{
        .name = "absolute",
        .fields = &.{"absolute"},
    },
    .{
        .name = "minWidth",
        .fields = &.{"min_width"},
    },
    .{
        .name = "maxWidth",
        .fields = &.{"max_width"},
    },
    .{
        .name = "minHeight",
        .fields = &.{"min_height"},
    },
    .{
        .name = "maxHeight",
        .fields = &.{"max_height"},
    },
    .{
        .name = "cell",
        .fields = &.{"cell"},
    },
    .{
        .name = "arc",
        .fields = &.{"arc"},
        .layout = false,
    },
    .{
        .name = "network",
        .fields = &.{"network"},
        .layout = false,
    },
    .{
        .name = "count",
        .fields = &.{"count"},
        .layout = false,
    },
    .{
        .name = "innerScale",
        .fields = &.{"inner_scale"},
        .layout = false,
    },
    .{
        .name = "op",
        .fields = &.{"boolean_op"},
        .layout = false,
    },
    .{
        .name = "geometry",
        .fields = &.{"geometry"},
        .layout = false,
        .override = false,
    },
    .{
        .name = "mask",
        .fields = &.{"mask"},
    },
    .{
        .name = "repeat",
        .fields = &.{"repeat"},
    },
    .{
        .name = "reverseZ",
        .fields = &.{"reverse_z"},
        .layout = false,
    },
    .{
        .name = "properties",
        .fields = &.{"properties"},
        .layout = false,
        .override = false,
        .visual = false,
    },
    .{
        .name = "bind",
        .fields = &.{"bind"},
        .layout = false,
        .override = false,
        .visual = false,
    },
    .{
        .name = "props",
        .fields = &.{"props"},
        .layout = false,
        .visual = false,
    },
    .{
        .name = "overrides",
        .fields = &.{"overrides"},
        .layout = false,
        .override = false,
        .visual = false,
    },
    .{
        .name = "vars",
        .fields = &.{"vars"},
        .layout = false,
        .visual = false,
    },
    .{
        .name = "modes",
        .fields = &.{"modes"},
        .layout = false,
        .visual = false,
    },
    .{
        .name = "text",
        .fields = &.{"text"},
        .text = true,
    },
    .{
        .name = "skipInk",
        .fields = &.{"skip_ink"},
        .text = true,
        .layout = false,
    },
    .{
        .name = "style",
        .fields = &.{"style"},
        .text = true,
    },
    .{
        .name = "runs",
        .fields = &.{"runs"},
        .text = true,
    },
    .{
        .name = "resize",
        .fields = &.{"resize"},
        .text = true,
    },
    .{
        .name = "align",
        .fields = &.{"align"},
        .text = true,
    },
    .{
        .name = "valign",
        .fields = &.{"valign"},
        .text = true,
    },
    .{
        .name = "truncation",
        .fields = &.{"truncation"},
        .text = true,
    },
    .{
        .name = "maxLines",
        .fields = &.{"max_lines"},
        .text = true,
    },
    .{
        .name = "wrap",
        .fields = &.{"wrap"},
        .text = true,
    },
    .{
        .name = "leadingTrim",
        .fields = &.{"leading_trim"},
        .text = true,
    },
    .{
        .name = "hangingPunctuation",
        .fields = &.{"hanging_punctuation"},
        .text = true,
    },
    .{
        .name = "hangingList",
        .fields = &.{"hanging_list"},
        .text = true,
    },
    .{
        .name = "lists",
        .fields = &.{"lists"},
        .text = true,
    },
    .{
        .name = "pathStart",
        .fields = &.{"path_start"},
        .text = true,
    },
    .{
        .name = "glyphs",
        .fields = &.{"glyphs"},
        .text = true,
        .layout = false,
        .override = false,
    },
    .{
        .name = "glyphRects",
        .fields = &.{"glyph_rects"},
        .text = true,
        .layout = false,
        .override = false,
    },
};

/// The text keys whose change drops the text's stored layout (`glyphs`, `glyphRects`),
/// as the spec asks of a tool that changes the text.
pub const text_content = [_][]const u8{ "text", "style", "runs", "resize", "align", "valign", "truncation", "maxLines", "wrap", "leadingTrim", "hangingPunctuation", "hangingList", "lists", "pathStart" };

pub fn find(name: []const u8) ?*const Key {
    for (&keys) |*k| if (std.mem.eql(u8, k.name, name)) return k;
    return null;
}

pub const Error = error{
    /// Not a key a node has (or `id`, `type`, `children`, which no set changes).
    UnknownKey,
    /// A text key on a node that is not text.
    NotText,
    /// A set needs a JSON object.
    NotAnObject,
} || anyerror;

/// Copies the fields named `names` of `src` into `dst` (same type), as they are.
fn copyFields(comptime T: type, dst: *T, src: *const T, names: []const []const u8) void {
    for (names) |name| {
        inline for (@typeInfo(T).@"struct".fields) |f| {
            if (std.mem.eql(u8, f.name, name)) @field(dst, f.name) = @field(src, f.name);
        }
    }
}

/// Deep copies the fields named `names` of `src` into `dst` (same type) in `a`.
fn takeFields(comptime T: type, a: Allocator, dst: *T, src: *const T, names: []const []const u8) !void {
    for (names) |name| {
        inline for (@typeInfo(T).@"struct".fields) |f| {
            if (std.mem.eql(u8, f.name, name)) @field(dst, f.name) = try m.deepCopy(a, @field(src, f.name));
        }
    }
}

/// The values of keys `names` of `n` as a JSON object (`{"fills": [...], "name": null}`;
/// null where the node has the default), numbers exactly as they are. Owned by `gpa`.
pub fn values(gpa: Allocator, n: *const m.Node, names: []const []const u8) Error![]u8 {
    var probe: m.Node = .{
        .id = n.id,
        .kind = n.kind,
    };
    var text: m.Text = .{};
    var any_text = false;
    for (names) |name| {
        const k = find(name) orelse return error.UnknownKey;
        if (k.text) {
            const t = if (n.text) |*t| t else continue;
            any_text = true;
            copyFields(m.Text, &text, t, k.fields);
        } else {
            copyFields(m.Node, &probe, n, k.fields);
            // The writer writes `stroke` only with strokes to draw.
            if (std.mem.eql(u8, name, "stroke")) probe.strokes = n.strokes;
        }
    }
    if (any_text) probe.text = text;
    const json = try write.nodeJson(gpa, &probe, .{
        .children = false,
    });
    defer gpa.free(json);
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    const v = try read.parseValue(scratch.allocator(), json);
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    var s: std.json.Stringify = .{
        .writer = &out.writer,
    };
    try s.beginObject();
    for (names) |name| {
        try s.objectField(name);
        try s.write(v.object.get(name) orelse .null);
    }
    try s.endObject();
    return out.toOwnedSlice();
}

/// Sets keys of `n` from `patch` (key to Pubd JSON value; `null` puts back the default).
/// What the patch names is built anew in `a`; everything else is left as it is.
pub fn apply(gpa: Allocator, a: Allocator, n: *m.Node, patch: std.json.ObjectMap) Error!void {
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    const sa = scratch.allocator();
    var obj: std.json.ObjectMap = .empty;
    try obj.put(sa, "id", .{
        .string = n.id,
    });
    var kind_buf: [40]u8 = undefined;
    try obj.put(sa, "type", .{
        .string = kindName(&kind_buf, n.kind),
    });
    var it = patch.iterator();
    while (it.next()) |e| {
        const k = find(e.key_ptr.*) orelse return error.UnknownKey;
        if (k.text and n.kind != .text) return error.NotText;
        if (e.value_ptr.* != .null) try obj.put(sa, e.key_ptr.*, e.value_ptr.*);
    }
    const tmp = try read.nodeOf(sa, .{
        .object = obj,
    });
    it = patch.iterator();
    while (it.next()) |e| {
        const k = find(e.key_ptr.*).?;
        if (k.text) {
            if (n.text == null) n.text = .{};
            try takeFields(m.Text, a, &n.text.?, &tmp.text.?, k.fields);
        } else try takeFields(m.Node, a, n, &tmp, k.fields);
    }
}

/// `apply` from JSON text (an object).
pub fn applyJson(gpa: Allocator, a: Allocator, n: *m.Node, json: []const u8) Error!void {
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    const v = try read.parseValue(scratch.allocator(), json);
    if (v != .object) return error.NotAnObject;
    return apply(gpa, a, n, v.object);
}

/// A kind as Pubd spells it (`component-set`).
pub fn kindName(buf: *[40]u8, k: m.Kind) []const u8 {
    const name = @tagName(k);
    for (name, buf[0..name.len]) |c, *o| o.* = if (c == '_') '-' else c;
    return buf[0..name.len];
}

test "every field of a node is some key's" {
    const own = [_][]const u8{ "id", "children", "rev", "shape_rev", "tree_rev", "edits" };
    inline for (@typeInfo(m.Node).@"struct".fields) |f| {
        var found = false;
        for (own) |o| found = found or std.mem.eql(u8, o, f.name);
        for (keys) |k| if (!k.text) for (k.fields) |x| {
            found = found or std.mem.eql(u8, x, f.name);
        };
        // `text` is the node's text: its fields are keys of their own.
        found = found or std.mem.eql(u8, f.name, "text");
        if (!found) {
            std.debug.print("node field {s} has no key\n", .{f.name});
            return error.TestUnexpectedResult;
        }
    }
    inline for (@typeInfo(m.Text).@"struct".fields) |f| {
        var found = false;
        for (keys) |k| if (k.text) for (k.fields) |x| {
            found = found or std.mem.eql(u8, x, f.name);
        };
        if (!found) {
            std.debug.print("text field {s} has no key\n", .{f.name});
            return error.TestUnexpectedResult;
        }
    }
}

test "a key is read and set without touching the others" {
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var fills = [_]m.Paint{.{
        .kind = .solid,
        .color = .{
            .r = 0.1,
        },
    }};
    var n: m.Node = .{
        .id = "1:2",
        .kind = .rectangle,
        .name = "R",
        .fills = &fills,
        .opacity = 0.3,
        .size = .{
            .x = 10.123457,
            .y = 4,
        },
    };
    const before = try values(gpa, &n, &.{ "fills", "opacity", "size", "effects" });
    defer gpa.free(before);
    try std.testing.expectEqualStrings("{\"fills\":[{\"type\":\"solid\",\"color\":[0.1,0,0]}],\"opacity\":0.3,\"size\":[10.123457,4],\"effects\":null}", before);
    try applyJson(gpa, a, &n, "{\"opacity\":null,\"name\":\"S\",\"size\":[1,2]}");
    try std.testing.expectEqual(@as(f32, 1), n.opacity);
    try std.testing.expectEqualStrings("S", n.name);
    try std.testing.expectEqual(@as(f32, 2), n.size.y);
    try std.testing.expect(n.fills.ptr == &fills);
    // Back as it was, exactly.
    try applyJson(gpa, a, &n, before);
    try std.testing.expectEqual(@as(f32, 10.123457), n.size.x);
    try std.testing.expectEqual(@as(f32, 0.3), n.opacity);
    try std.testing.expectError(error.UnknownKey, applyJson(gpa, a, &n, "{\"children\":[]}"));
    try std.testing.expectError(error.NotText, applyJson(gpa, a, &n, "{\"text\":\"x\"}"));
}
