//! A model value as flat bytes and back, for handing nodes between engines built from the
//! same code (a render worker reads a page's JSON, the engine that draws takes the
//! nodes): parts with no slices in them are copied as they lie in memory, slices as a
//! length and their items. Not a file format: both ends must be the same build.

const std = @import("std");

/// Whether `T` holds a slice or a pointer anywhere (else its bytes are the value).
fn hasPointers(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => true,
        .optional => |o| hasPointers(o.child),
        .array => |a| hasPointers(a.child),
        .@"struct" => |s| blk: {
            for (s.field_types) |Field| if (hasPointers(Field)) break :blk true;
            break :blk false;
        },
        .@"union" => |u| blk: {
            for (u.field_types) |Field| if (hasPointers(Field)) break :blk true;
            break :blk false;
        },
        .bool, .int, .float, .@"enum", .void => false,
        else => @compileError("blob: no encoding for " ++ @typeName(T)),
    };
}

/// Appends `v` to `out`.
pub fn encode(gpa: std.mem.Allocator, out: *std.ArrayList(u8), v: anytype) error{OutOfMemory}!void {
    const T = @TypeOf(v);
    if (comptime !hasPointers(T)) return out.appendSlice(gpa, std.mem.asBytes(&v));
    switch (@typeInfo(T)) {
        .pointer => |p| {
            if (p.size != .slice) @compileError("blob: only slices, not " ++ @typeName(T));
            try out.appendSlice(gpa, std.mem.asBytes(&@as(u32, @intCast(v.len))));
            if (comptime !hasPointers(p.child)) {
                try out.appendSlice(gpa, std.mem.sliceAsBytes(v));
            } else for (v) |x| try encode(gpa, out, x);
        },
        .optional => {
            if (v) |x| {
                try out.append(gpa, 1);
                try encode(gpa, out, x);
            } else try out.append(gpa, 0);
        },
        .array => for (v) |x| try encode(gpa, out, x),
        .@"struct" => |s| inline for (s.field_names) |field_name| try encode(gpa, out, @field(v, field_name)),
        .@"union" => |u| {
            if (u.tag_type == null) @compileError("blob: untagged union " ++ @typeName(T));
            switch (v) {
                inline else => |x, tag| {
                    try out.appendSlice(gpa, std.mem.asBytes(&@as(u32, @backingInt(tag))));
                    try encode(gpa, out, x);
                },
            }
        },
        else => unreachable,
    }
}

pub const Reader = struct {
    bytes: []const u8,
    at: usize = 0,

    fn take(self: *Reader, n: usize) error{BadBlob}![]const u8 {
        if (self.bytes.len - self.at < n) return error.BadBlob;
        const s = self.bytes[self.at..][0..n];
        self.at += n;
        return s;
    }

    fn raw(self: *Reader, comptime T: type) error{BadBlob}!T {
        var v: T = undefined;
        @memcpy(std.mem.asBytes(&v), try self.take(@sizeOf(T)));
        return v;
    }
};

/// A `T` read from `r`, its slices in `a`.
pub fn decode(comptime T: type, a: std.mem.Allocator, r: *Reader) error{ OutOfMemory, BadBlob }!T {
    if (comptime !hasPointers(T)) return r.raw(T);
    switch (@typeInfo(T)) {
        .pointer => |p| {
            const n = try r.raw(u32);
            if (n == 0) return &.{};
            if (comptime !hasPointers(p.child)) {
                const src = try r.take(@as(usize, n) * @sizeOf(p.child));
                const out = try a.alloc(p.child, n);
                @memcpy(std.mem.sliceAsBytes(out), src);
                return out;
            }
            const out = try a.alloc(p.child, n);
            for (out) |*o| o.* = try decode(p.child, a, r);
            return out;
        },
        .optional => |o| {
            const has = (try r.take(1))[0];
            return if (has != 0) try decode(o.child, a, r) else null;
        },
        .array => |arr| {
            var out: T = undefined;
            for (&out) |*o| o.* = try decode(arr.child, a, r);
            return out;
        },
        .@"struct" => |s| {
            var out: T = undefined;
            inline for (s.field_names, s.field_types) |field_name, Field| @field(out, field_name) = try decode(Field, a, r);
            return out;
        },
        .@"union" => |u| {
            const tag = try r.raw(u32);
            inline for (u.field_names, u.field_types) |field_name, Field| {
                if (@backingInt(@field(u.tag_type.?, field_name)) == tag) return @unionInit(T, field_name, try decode(Field, a, r));
            }
            return error.BadBlob;
        },
        else => unreachable,
    }
}

test "a node goes to bytes and back the same" {
    const m = @import("model.zig");
    const read = @import("read.zig");
    const write = @import("write.zig");
    const gpa = std.testing.allocator;
    const json =
        \\{"id":"1:2","type":"frame","name":"Card","size":[120,80],"radius":[4,4,4,4],
        \\ "fills":[{"type":"solid","color":"#ff0000","var":"1:9"}],
        \\ "effects":[{"type":"drop-shadow","color":"#00000040","offset":[0,2],"radius":6}],
        \\ "layout":{"mode":"vertical","padding":[8,8,8,8],"gap":4},
        \\ "vars":{"padding/1":"6:1"},
        \\ "children":[{"id":"1:3","type":"text","name":"Label","size":[60,20],
        \\   "text":{"characters":"Hi there","style":{"family":"Inter","style":"Regular","size":14}}},
        \\  {"id":"1:4","type":"vector","size":[10,10],
        \\   "geometry":[{"d":"M0 0L10 0L10 10Z"}]}]}
    ;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const n = try read.nodeFromJson(gpa, a, json, .{});
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(gpa);
    try encode(gpa, &bytes, n);
    var r: Reader = .{
        .bytes = bytes.items,
    };
    const back = try decode(m.Node, a, &r);
    try std.testing.expectEqual(bytes.items.len, r.at);
    // The same node: the same bytes again, and the same JSON.
    var again: std.ArrayList(u8) = .empty;
    defer again.deinit(gpa);
    try encode(gpa, &again, back);
    try std.testing.expectEqualSlices(u8, bytes.items, again.items);
    const j0 = try write.nodeJson(gpa, &n, .{});
    defer gpa.free(j0);
    const j1 = try write.nodeJson(gpa, &back, .{});
    defer gpa.free(j1);
    try std.testing.expectEqualStrings(j0, j1);
}
