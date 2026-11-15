//! A `.fig` file opened for reading: the zip's directory, then `canvas.fig` and
//! `meta.json` read out of it. Images are never read: the design system needs none.

const std = @import("std");
const engine = @import("publr_engine");

const Io = std.Io;
const Dir = std.Io.Dir;
const C = engine.fig_container;

pub const Canvas = struct {
    canvas: []const u8,
    meta: ?[]const u8,
};

/// `canvas.fig` and `meta.json` of the `.fig` at `path`, in `a`.
pub fn read(io: Io, a: std.mem.Allocator, path: []const u8) !Canvas {
    const file = try Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const size = try file.length(io);
    const tail = try a.alloc(u8, @intCast(@min(size, C.max_tail)));
    _ = try file.readPositionalAll(io, tail, size - tail.len);
    const dir = try C.findDirectory(tail, size);
    const cd = try a.alloc(u8, @intCast(dir.size));
    _ = try file.readPositionalAll(io, cd, dir.offset);
    const items = try C.listDirectory(a, cd, dir.count);
    var out: Canvas = .{
        .canvas = &.{},
        .meta = null,
    };
    var found = false;
    for (items) |it| {
        if (std.mem.eql(u8, it.name, "canvas.fig")) {
            out.canvas = try entry(io, a, file, it);
            found = true;
        }
        if (std.mem.eql(u8, it.name, "meta.json")) out.meta = try entry(io, a, file, it);
    }
    if (!found) return error.NotAFigFile;
    return out;
}

fn entry(io: Io, a: std.mem.Allocator, file: Io.File, it: C.Item) ![]u8 {
    var head: [30]u8 = undefined;
    _ = try file.readPositionalAll(io, &head, it.local);
    const start = it.local + try C.dataStart(&head);
    const raw = try a.alloc(u8, @intCast(it.csize));
    _ = try file.readPositionalAll(io, raw, start);
    if (it.method == 0) return raw;
    if (it.method != 8) return error.UnsupportedZip;
    return C.inflateRaw(a, raw, @intCast(@min(it.size, C.max_inflated)));
}

/// A Kiwi value as JSON, for looking at what a file holds (`probe`). Byte arrays are
/// written as their length; arrays longer than `max_items` are cut.
pub fn dumpValue(w: *Io.Writer, s: *const engine.kiwi.Schema, v: engine.kiwi.Value, max_items: usize) !void {
    switch (v) {
        .bool => |b| try w.print("{}", .{b}),
        .byte => |b| try w.print("{d}", .{b}),
        .int => |i| try w.print("{d}", .{i}),
        .uint => |u| try w.print("{d}", .{u}),
        .float => |f| if (std.math.isFinite(f)) try w.print("{d}", .{f}) else try w.writeAll("null"),
        .int64 => |i| try w.print("{d}", .{i}),
        .uint64 => |u| try w.print("{d}", .{u}),
        .string => |str| try std.json.Stringify.value(str, .{}, w),
        .bytes => |b| try w.print("\"<{d} bytes>\"", .{b.len}),
        .@"enum" => |e| try w.print("\"{s}\"", .{s.defs[e.def].enumName(e.value) orelse "?"}),
        .array => |items| {
            try w.writeByte('[');
            for (items, 0..) |x, i| {
                if (i >= max_items) {
                    try w.print(",\"... {d} more\"", .{items.len - i});
                    break;
                }
                if (i > 0) try w.writeByte(',');
                try dumpValue(w, s, x, max_items);
            }
            try w.writeByte(']');
        },
        .record => |r| {
            const d = &s.defs[r.def];
            try w.writeByte('{');
            for (r.entries, 0..) |e, i| {
                if (i > 0) try w.writeByte(',');
                try w.print("\"{s}\":", .{d.fields[e.field].name});
                try dumpValue(w, s, e.value, max_items);
            }
            try w.writeByte('}');
        },
    }
}
