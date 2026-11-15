//! Bring in, step 1 (research): one design system read from any source design file.
//!
//!   bring-in probe <file.fig> types | <TYPE> [count] [has-field]
//!   bring-in gather <source.fig | doc.pubd-dir> <evidence.json>
//!   bring-in build <plan.json> <out.pubd-dir>
//!   bring-in verify <evidence.json> <plan.json> <coverage.json>
//!   bring-in leftovers <plan.json> <evidence.json> <coverage.json> <out.pubd-dir>

const std = @import("std");
const engine = @import("publr_engine");
const figfile = @import("figfile.zig");
const gather = @import("gather.zig");
const build = @import("make.zig");
const verify = @import("verify.zig");
const leftovers = @import("leftovers.zig");

const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    var out_buf: [8192]u8 = undefined;
    var stdout: Io.File.Writer = .init(.stdout(), io, &out_buf);
    const w = &stdout.interface;
    defer w.flush() catch {};

    if (args.len >= 4 and std.mem.eql(u8, args[1], "probe")) return probe(io, gpa, w, args[2..]);
    if (args.len >= 4 and std.mem.eql(u8, args[1], "gather")) {
        // `--skip-pages a,b`: pages whose names hold any of these are not read.
        var skip: std.ArrayList([]const u8) = .empty;
        if (args.len >= 6 and std.mem.eql(u8, args[4], "--skip-pages")) {
            var it = std.mem.tokenizeScalar(u8, args[5], ',');
            while (it.next()) |x| try skip.append(arena, x);
        }
        return gather.runWith(io, gpa, w, args[2], args[3], skip.items);
    }
    if (args.len >= 4 and std.mem.eql(u8, args[1], "build")) return build.run(io, gpa, w, args[2], args[3]);
    if (args.len >= 5 and std.mem.eql(u8, args[1], "verify")) return verify.run(io, gpa, w, args[2], args[3], args[4]);
    if (args.len >= 6 and std.mem.eql(u8, args[1], "leftovers")) return leftovers.run(io, gpa, w, args[2], args[3], args[4], args[5]);
    try w.writeAll(
        \\bring-in probe <file.fig> types | <TYPE> [count] [has-field]
        \\bring-in gather <source.fig | doc.pubd-dir> <evidence.json>
        \\bring-in build <plan.json> <out.pubd-dir>
        \\bring-in verify <evidence.json> <plan.json> <coverage.json>
        \\bring-in leftovers <plan.json> <evidence.json> <coverage.json> <out.pubd-dir>
        \\
    );
}

/// What a `.fig` holds, record by record: counts of node types, or the records of one
/// type as JSON (the first `count`, optionally only those with field `has-field`).
fn probe(io: Io, gpa: std.mem.Allocator, w: *Io.Writer, args: []const []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const c = try figfile.read(io, a, args[0]);
    const im = try engine.fig.Importer.create(gpa, c.canvas, c.meta);
    defer im.destroy();
    const want = args[1];
    if (std.mem.eql(u8, want, "schema")) {
        // Every field whose name holds `args[2]`, by definition.
        for (im.ctx.s.defs) |d| for (d.fields) |f| {
            if (std.ascii.findIgnoreCase(f.name, args[2]) != null) try w.print("{s}.{s}\n", .{ d.name, f.name });
        };
        return;
    }
    const count: usize = if (args.len >= 3) try std.fmt.parseInt(usize, args[2], 10) else 5;
    const has: ?[]const u8 = if (args.len >= 4) args[3] else null;
    var counts: std.StringArrayHashMapUnmanaged(u32) = .empty;
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    var shown: usize = 0;
    for (im.offsets) |at| {
        _ = scratch.reset(.retain_capacity);
        const v: engine.kiwi.View = .{
            .s = im.ctx.s,
            .v = try engine.kiwi.decodeAt(scratch.allocator(), im.ctx.s, im.ctx.node_def, im.data, at),
        };
        const t = v.getEnum("type") orelse "?";
        if (std.mem.eql(u8, want, "types")) {
            const gop = try counts.getOrPut(a, try a.dupe(u8, t));
            if (!gop.found_existing) gop.value_ptr.* = 0;
            gop.value_ptr.* += 1;
            continue;
        }
        if (!std.mem.eql(u8, t, want) and !std.mem.eql(u8, want, "*")) continue;
        if (has) |h| if (v.get(h) == null) continue;
        try figfile.dumpValue(w, im.ctx.s, v.v, 12);
        try w.writeByte('\n');
        shown += 1;
        if (shown >= count) break;
    }
    for (counts.keys(), counts.values()) |k, n| try w.print("{s} {d}\n", .{ k, n });
}
