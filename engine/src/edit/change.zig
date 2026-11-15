//! A change to a document: the few kinds that cover every edit, each with a JSON form and
//! an inverse (`pubd/SPEC.md` for the node JSON they carry).
//!
//!   {"op":"set","node":"1:2","props":{"fills":[...],"opacity":null}}
//!   {"op":"insert","parent":"1:1","index":3,"node":{ Pubd node, with its children }}
//!   {"op":"delete","node":"1:5"}
//!   {"op":"move","node":"1:5","parent":"1:9","index":0}
//!   {"op":"style","id":"S:1","style":{ Pubd style } | null}
//!   {"op":"variable","id":"V:1","variable":{ Pubd variable } | null,"index":4}
//!   {"op":"collection","id":"C:1","collection":{ Pubd collection } | null,"index":0}
//!
//! `parent` "" is the document: its children are the pages, so adding or removing a page
//! is an insert or a delete there. `index` is where the node ends up among its parent's
//! children. A `set` value `null` puts back the key's default; `set` on node "" names the
//! document (its `name`). A variable or collection is as `document.json` keeps it under
//! its id; `index` (optional) is its place in the document's list, else it keeps its
//! place (a new one goes last).

const std = @import("std");
const jv = @import("../jv.zig");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const Stringify = std.json.Stringify;

pub const Op = enum {
    set,
    insert,
    delete,
    move,
    style,
    variable,
    collection,
};

/// One change. Strings are JSON text where they hold values (`json`).
pub const Change = struct {
    op: Op,
    /// set, delete, move: the node; insert: the inserted node's id; style, variable,
    /// collection: its id.
    node: []const u8 = "",
    /// insert, move: the parent ("" the document).
    parent: []const u8 = "",
    /// insert, move: the place among the parent's children; variable, collection: the
    /// place in the document's list (`end`: where it is, or last).
    index: u32 = 0,
    /// set: the properties (a JSON object); insert: the node (Pubd JSON); style: the
    /// style (a JSON object, or `null` for none).
    json: []const u8 = "null",
    /// insert of a page (parent ""): the page's own file, when the page comes back as it
    /// was stored, not loaded (the undo of deleting a page that was never read).
    file: []const u8 = "",

    /// A deep copy in `a`.
    pub fn dupe(c: Change, a: Allocator) !Change {
        return .{
            .op = c.op,
            .node = try a.dupe(u8, c.node),
            .parent = try a.dupe(u8, c.parent),
            .index = c.index,
            .json = try a.dupe(u8, c.json),
            .file = try a.dupe(u8, c.file),
        };
    }

    /// Writes the change's JSON form.
    pub fn write(c: Change, s: *Stringify) !void {
        try s.beginObject();
        try s.objectField("op");
        try s.write(@tagName(c.op));
        switch (c.op) {
            .set => {
                try s.objectField("node");
                try s.write(c.node);
                try s.objectField("props");
                try raw(s, c.json);
            },
            .insert => {
                try s.objectField("parent");
                try s.write(c.parent);
                try s.objectField("index");
                try s.write(c.index);
                try s.objectField("node");
                try raw(s, c.json);
                if (c.file.len > 0) {
                    try s.objectField("file");
                    try s.write(c.file);
                }
            },
            .delete => {
                try s.objectField("node");
                try s.write(c.node);
            },
            .move => {
                try s.objectField("node");
                try s.write(c.node);
                try s.objectField("parent");
                try s.write(c.parent);
                try s.objectField("index");
                try s.write(c.index);
            },
            .style => {
                try s.objectField("id");
                try s.write(c.node);
                try s.objectField("style");
                try raw(s, c.json);
            },
            .variable, .collection => {
                try s.objectField("id");
                try s.write(c.node);
                try s.objectField(@tagName(c.op));
                try raw(s, c.json);
                if (c.index != end) {
                    try s.objectField("index");
                    try s.write(c.index);
                }
            },
        }
        try s.endObject();
    }

    /// The JSON form, owned by `gpa`.
    pub fn toJson(c: Change, gpa: Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        var s: Stringify = .{
            .writer = &out.writer,
        };
        try c.write(&s);
        return out.toOwnedSlice();
    }

    /// Reads a change from its parsed JSON form; strings are copied into `a`. An insert's
    /// `index` may be missing or negative: the end.
    pub fn fromValue(a: Allocator, v: Value) !Change {
        const op = std.meta.stringToEnum(Op, jv.str(v, "op") orelse return error.BadChange) orelse return error.BadChange;
        var c: Change = .{
            .op = op,
        };
        switch (op) {
            .set => {
                c.node = try a.dupe(u8, jv.str(v, "node") orelse return error.BadChange);
                const p = jv.get(v, "props") orelse return error.BadChange;
                if (p != .object) return error.BadChange;
                c.json = try Stringify.valueAlloc(a, p, .{});
            },
            .insert => {
                c.parent = try a.dupe(u8, jv.str(v, "parent") orelse "");
                c.index = indexOf(v);
                const n = jv.get(v, "node") orelse return error.BadChange;
                if (n != .object) return error.BadChange;
                c.node = try a.dupe(u8, jv.str(n, "id") orelse "");
                c.json = try Stringify.valueAlloc(a, n, .{});
                c.file = try a.dupe(u8, jv.str(v, "file") orelse "");
            },
            .delete => c.node = try a.dupe(u8, jv.str(v, "node") orelse return error.BadChange),
            .move => {
                c.node = try a.dupe(u8, jv.str(v, "node") orelse return error.BadChange);
                c.parent = try a.dupe(u8, jv.str(v, "parent") orelse return error.BadChange);
                c.index = indexOf(v);
            },
            .style => {
                c.node = try a.dupe(u8, jv.str(v, "id") orelse return error.BadChange);
                c.json = try Stringify.valueAlloc(a, jv.get(v, "style") orelse .null, .{});
            },
            .variable, .collection => {
                c.node = try a.dupe(u8, jv.str(v, "id") orelse return error.BadChange);
                c.json = try Stringify.valueAlloc(a, jv.get(v, @tagName(op)) orelse .null, .{});
                c.index = indexOf(v);
            },
        }
        return c;
    }

    /// The end of the parent's children.
    pub const end = std.math.maxInt(u32);

    fn indexOf(v: Value) u32 {
        const x = jv.num(v, "index") orelse return end;
        if (x < 0) return end;
        return @intFromFloat(@min(x, 1e9));
    }

    /// Bytes the change holds (for what the undo history costs).
    pub fn bytes(c: Change) usize {
        return @sizeOf(Change) + c.node.len + c.parent.len + c.json.len + c.file.len;
    }
};

fn raw(s: *Stringify, json: []const u8) !void {
    try s.beginWriteRaw();
    try s.writer.writeAll(json);
    s.endWriteRaw();
}

test "a change survives its JSON form" {
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const forms = [_][]const u8{
        "{\"op\":\"set\",\"node\":\"1:2\",\"props\":{\"opacity\":0.5,\"name\":null}}",
        "{\"op\":\"insert\",\"parent\":\"1:1\",\"index\":3,\"node\":{\"id\":\"9:1\",\"type\":\"rectangle\"}}",
        "{\"op\":\"insert\",\"parent\":\"\",\"index\":2,\"node\":{\"id\":\"0:3\",\"type\":\"page\"},\"file\":\"pages/0_3.json\"}",
        "{\"op\":\"delete\",\"node\":\"1:5\"}",
        "{\"op\":\"move\",\"node\":\"1:5\",\"parent\":\"\",\"index\":0}",
        "{\"op\":\"style\",\"id\":\"S:1\",\"style\":null}",
        "{\"op\":\"variable\",\"id\":\"V:1\",\"variable\":{\"name\":\"gap\",\"collection\":\"C:1\",\"type\":\"number\",\"values\":{\"m:1\":8}},\"index\":2}",
        "{\"op\":\"collection\",\"id\":\"C:1\",\"collection\":null}",
    };
    for (forms) |f| {
        const v = try std.json.parseFromSliceLeaky(Value, a, f, .{});
        const c = try Change.fromValue(a, v);
        const back = try c.toJson(a);
        try std.testing.expectEqualStrings(f, back);
    }
}
