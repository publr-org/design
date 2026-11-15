//! Opening a `.pubd` folder into a session: the document, its pages kept apart, its
//! assets (decoded when first drawn) and the corpus fonts beside it.

const std = @import("std");
const engine = @import("publr_engine");

const Io = std.Io;
const Dir = std.Io.Dir;
const Session = engine.session.Session;

const max_file = 512 * 1024 * 1024;

pub fn open(io: Io, gpa: std.mem.Allocator, session: *Session, dir: []const u8) !void {
    const cwd = Dir.cwd();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    try session.loadPubd(try cwd.readFileAlloc(io, try std.fs.path.join(a, &.{ dir, "document.json" }), a, .limited(max_file)));
    for (0..session.pages().len) |i| if (session.pageFile(i)) |f| {
        try session.loadPage(i, try cwd.readFileAlloc(io, try std.fs.path.join(a, &.{ dir, f }), a, .limited(max_file)));
    };
    const assets = try std.fs.path.join(a, &.{ dir, "assets" });
    if (cwd.openDir(io, assets, .{
        .iterate = true,
    })) |ad_const| {
        var ad = ad_const;
        defer ad.close(io);
        var it = ad.iterate();
        while (try it.next(io)) |e| {
            if (e.kind != .file) continue;
            const bytes = try cwd.readFileAlloc(io, try std.fs.path.join(a, &.{ assets, e.name }), gpa, .limited(max_file));
            try session.addAssetOwned(e.name, bytes);
        }
    } else |_| {}
    try loadFonts(io, gpa, session, a, dir);
}

/// The corpus fonts beside the document, as `pe` finds them: faces under `fonts/`,
/// fallbacks in `fonts-fallback/` in `order.txt` order, variable fonts in `fonts-variable/`.
fn loadFonts(io: Io, gpa: std.mem.Allocator, session: *Session, a: std.mem.Allocator, dir: []const u8) !void {
    const cwd = Dir.cwd();
    for ([_][]const u8{ "fonts", "../fonts", "../../fonts" }) |rel| {
        const root = try std.fs.path.join(a, &.{ dir, rel });
        var probe = cwd.openDir(io, root, .{}) catch continue;
        probe.close(io);
        try addFontDir(io, gpa, session, a, root, .face, 0);
        const fb = try std.fs.path.join(a, &.{ root, "..", "fonts-fallback" });
        if (cwd.readFileAlloc(io, try std.fs.path.join(a, &.{ fb, "order.txt" }), a, .limited(64 * 1024))) |order| {
            var it = std.mem.tokenizeAny(u8, order, "\r\n");
            while (it.next()) |name| {
                const bytes = cwd.readFileAlloc(io, try std.fs.path.join(a, &.{ fb, std.mem.trim(u8, name, " ") }), gpa, .limited(max_file)) catch continue;
                _ = try session.addFontOwned(bytes, .fallback);
            }
        } else |_| {}
        try addFontDir(io, gpa, session, a, try std.fs.path.join(a, &.{ root, "..", "fonts-variable" }), .variable, 2);
        return;
    }
}

fn addFontDir(io: Io, gpa: std.mem.Allocator, session: *Session, a: std.mem.Allocator, path: []const u8, role: engine.fonts.Role, depth: u8) !void {
    var d = Dir.cwd().openDir(io, path, .{
        .iterate = true,
    }) catch return;
    defer d.close(io);
    var it = d.iterate();
    while (try it.next(io)) |e| {
        const p = try std.fs.path.join(a, &.{ path, e.name });
        if (e.kind == .directory and depth < 2) try addFontDir(io, gpa, session, a, p, role, depth + 1);
        if (e.kind != .file or !engine.fonts.isFontFile(e.name)) continue;
        const bytes = Dir.cwd().readFileAlloc(io, p, gpa, .limited(max_file)) catch continue;
        _ = try session.addFontOwned(bytes, role);
    }
}
