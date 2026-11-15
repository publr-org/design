//! The binary blobs a `.fig` message carries next to its nodes (`Message.blobs[i].bytes`),
//! decoded. Layouts derived from our own files by comparing each blob with the REST API's
//! answer for the same node (see docs/fig-format.md).

const std = @import("std");
const m = @import("../../pubd/model.zig");

pub const Error = error{
    /// The blob ends inside a record, or holds a command or index it cannot.
    BadBlob,
    OutOfMemory,
};

/// The most items a network may declare (anything larger is corrupt).
const max_items = 1 << 20;

/// A path as commands: a byte each, then its points as little-endian f32 pairs.
///
///   0  close            (no points)
///   1  move to          x y
///   2  line to          x y
///   3  quadratic to     cx cy x y
///   4  cubic to         c1x c1y c2x c2y x y
///
/// Returned as SVG path data (absolute M, L, Q, C, Z), shortest round-trip numbers.
pub fn commandsToSvg(a: std.mem.Allocator, bytes: []const u8) Error![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    const w = &out.writer;
    var i: usize = 0;
    var open = false;
    while (i < bytes.len) {
        const c = bytes[i];
        i += 1;
        const n: usize = switch (c) {
            0 => 0,
            1, 2 => 2,
            3 => 4,
            4 => 6,
            else => return error.BadBlob,
        };
        if (bytes.len - i < n * 4) return error.BadBlob;
        if (c == 0) {
            // A leading or repeated close draws nothing.
            if (open) w.writeByte('Z') catch return error.OutOfMemory;
            open = false;
            continue;
        }
        w.writeByte("ZMLQC"[c]) catch return error.OutOfMemory;
        open = true;
        for (0..n) |k| {
            const f = readF32(bytes[i + k * 4 ..][0..4]);
            if (k > 0) w.writeByte(' ') catch return error.OutOfMemory;
            w.print("{d}", .{if (std.math.isFinite(f)) f else 0}) catch return error.OutOfMemory;
        }
        i += n * 4;
    }
    return out.toOwnedSlice() catch return error.OutOfMemory;
}

/// A vector network (`vectorData.vectorNetworkBlob`), all little-endian 32-bit words:
///
///   u32 vertex count, u32 segment count, u32 region count
///   vertex:  u32 style id, f32 x, f32 y
///   segment: u32 style id, u32 start vertex, f32 start tangent x, y,
///            u32 end vertex, f32 end tangent x, y
///   region:  u32 (style id << 1 | 1 for nonzero, 0 for even-odd), u32 loop count,
///            then each loop: u32 segment count, u32 segment index...
///
/// Positions are in the node's `vectorData.normalizedSize` space (REST gives the same
/// numbers; the importer fits them to the node's size).
pub fn network(a: std.mem.Allocator, bytes: []const u8) Error!m.Network {
    var r: Words = .{
        .bytes = bytes,
    };
    const nv = try r.count();
    const ns = try r.count();
    const nr = try r.count();
    if (nv * 3 + ns * 7 > r.left()) return error.BadBlob;

    const verts = try a.alloc(m.Vec2, nv);
    for (verts) |*v| {
        _ = try r.word();
        v.* = .{
            .x = try r.float(),
            .y = try r.float(),
        };
    }
    const segs = try a.alloc(m.Segment, ns);
    for (segs) |*s| {
        _ = try r.word();
        const from = try r.word();
        const t0: m.Vec2 = .{
            .x = try r.float(),
            .y = try r.float(),
        };
        const to = try r.word();
        const t1: m.Vec2 = .{
            .x = try r.float(),
            .y = try r.float(),
        };
        if (from >= nv or to >= nv) return error.BadBlob;
        s.* = .{
            .from = from,
            .to = to,
            .t0 = t0,
            .t1 = t1,
        };
    }
    const regions = try a.alloc(m.Region, nr);
    for (regions) |*reg| {
        const head = try r.word();
        const nl = try r.count();
        const loops = try a.alloc([]u32, nl);
        for (loops) |*l| {
            const k = try r.count();
            if (k > r.left()) return error.BadBlob;
            const ids = try a.alloc(u32, k);
            for (ids) |*id| {
                id.* = try r.word();
                if (id.* >= ns) return error.BadBlob;
            }
            l.* = ids;
        }
        reg.* = .{
            .winding = if (head & 1 == 1) .nonzero else .evenodd,
            .loops = loops,
        };
    }
    return .{
        .vertices = verts,
        .segments = segs,
        .regions = regions,
    };
}

fn readF32(b: *const [4]u8) f32 {
    return @bitCast(std.mem.readInt(u32, b, .little));
}

const Words = struct {
    bytes: []const u8,
    at: usize = 0,

    fn left(r: *const Words) usize {
        return (r.bytes.len - r.at) / 4;
    }

    fn word(r: *Words) Error!u32 {
        if (r.bytes.len - r.at < 4) return error.BadBlob;
        defer r.at += 4;
        return std.mem.readInt(u32, r.bytes[r.at..][0..4], .little);
    }

    fn count(r: *Words) Error!u32 {
        const n = try r.word();
        if (n > max_items) return error.BadBlob;
        return n;
    }

    fn float(r: *Words) Error!f32 {
        const f: f32 = @bitCast(try r.word());
        return if (std.math.isFinite(f)) f else 0;
    }
};

test "commands to SVG" {
    const a = std.testing.allocator;
    var b: std.ArrayList(u8) = .empty;
    defer b.deinit(a);
    const put = struct {
        fn f(list: *std.ArrayList(u8), al: std.mem.Allocator, c: u8, pts: []const f32) !void {
            try list.append(al, c);
            for (pts) |p| {
                var w: [4]u8 = undefined;
                std.mem.writeInt(u32, &w, @bitCast(p), .little);
                try list.appendSlice(al, &w);
            }
        }
    }.f;
    try put(&b, a, 0, &.{});
    try put(&b, a, 1, &.{ 0, 0 });
    try put(&b, a, 2, &.{ 10, 0 });
    try put(&b, a, 3, &.{ 10, 5, 5, 5 });
    try put(&b, a, 4, &.{ 1, 2, 3, 4, 0.5, 0 });
    try put(&b, a, 0, &.{});
    const d = try commandsToSvg(a, b.items);
    defer a.free(d);
    try std.testing.expectEqualStrings("M0 0L10 0Q10 5 5 5C1 2 3 4 0.5 0Z", d);
    // Truncated or unknown commands are errors.
    try std.testing.expectError(error.BadBlob, commandsToSvg(a, b.items[0 .. b.items.len - 3]));
    try std.testing.expectError(error.BadBlob, commandsToSvg(a, &.{9}));
}

test "vector network" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Two vertices, one segment, one even-odd region with one loop.
    const words = [_]u32{
        2,                      1,                      1,
        0,                      0,                      0,
        0,                      @bitCast(@as(f32, 10)), 0,
        0,                      0,                      0,
        0,                      1,                      @bitCast(@as(f32, 2)),
        @bitCast(@as(f32, -1)), 0,                      1,
        1,                      0,
    };
    var bytes: [words.len * 4]u8 = undefined;
    for (words, 0..) |w, i| std.mem.writeInt(u32, bytes[i * 4 ..][0..4], w, .little);
    const net = try network(a, &bytes);
    try std.testing.expectEqual(@as(f32, 10), net.vertices[1].x);
    try std.testing.expectEqual(@as(u32, 1), net.segments[0].to);
    try std.testing.expectEqual(@as(f32, 2), net.segments[0].t1.x);
    try std.testing.expectEqual(@as(f32, -1), net.segments[0].t1.y);
    try std.testing.expectEqual(m.Winding.evenodd, net.regions[0].winding);
    try std.testing.expectEqual(@as(u32, 0), net.regions[0].loops[0][0]);
    var n: usize = 0;
    while (n < bytes.len) : (n += 4) try std.testing.expect(std.meta.isError(network(a, bytes[0..n])));
}
