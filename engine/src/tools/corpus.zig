//! Reading a `.pubd` folder for the tools: the document, its decoded images and lookups.

const std = @import("std");
const engine = @import("publr_engine");

const m = engine.model;
const Io = std.Io;
const Dir = std.Io.Dir;

/// Largest file the tools read.
pub const max_file = 512 * 1024 * 1024;

/// An asset's media type and pixel size, read from its first bytes.
pub const Sniffed = engine.sniff.Sniffed;

/// Tells PNG, JPEG and GIF apart and reads PNG and JPEG sizes.
pub const sniff = engine.sniff.sniff;

/// A document with its images decoded into mipmaps, ready to render.
pub const Loaded = struct {
    doc: m.Document,
    images: engine.render.Images,
    fonts: engine.layout.FontSet = .{},
    /// Font bytes and names.
    font_arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Loaded, gpa: std.mem.Allocator) void {
        var it = self.images.valueIterator();
        while (it.next()) |mip| mip.deinit(gpa);
        self.images.deinit(gpa);
        self.fonts.deinit(gpa);
        self.font_arena.deinit();
        self.doc.deinit();
    }
};

/// A renderer for a loaded document, with its fonts.
pub fn renderer(gpa: std.mem.Allocator, loaded: *const Loaded) engine.render.Renderer {
    var r = engine.render.Renderer.init(gpa, &loaded.images);
    r.fonts = &loaded.fonts;
    r.indexDocument(&loaded.doc) catch {};
    return r;
}

/// The font files a document uses, as paths, in the order they are added: faces, then
/// fallbacks, then variable fonts.
pub const FontFiles = struct {
    faces: []const []const u8 = &.{},
    fallbacks: []const []const u8 = &.{},
    variable: []const []const u8 = &.{},
    /// The `fonts` folder found (empty when none).
    root: []const u8 = "",
};

/// Every .ttf/.otf in the first `fonts` folder found in the document's folder or up to two
/// levels above it and in its subfolders (one per family); the fallbacks in
/// `fonts-fallback/` beside it in the order its `order.txt` lists them (one file name per
/// line); the variable fonts in `fonts-variable/` beside it. Allocates in `arena`.
pub fn fontFiles(io: Io, arena: std.mem.Allocator, dir: []const u8) !FontFiles {
    const cwd = Dir.cwd();
    for ([_][]const u8{ "fonts", "../fonts", "../../fonts" }) |rel| {
        const p = try std.fs.path.join(arena, &.{ dir, rel });
        var fd = cwd.openDir(io, p, .{
            .iterate = true,
        }) catch continue;
        fd.close(io);
        var faces: std.ArrayList([]const u8) = .empty;
        try listFontDir(io, arena, p, &faces, 0);

        var fallbacks: std.ArrayList([]const u8) = .empty;
        const fb_dir = try std.fs.path.join(arena, &.{ p, "..", "fonts-fallback" });
        const order_path = try std.fs.path.join(arena, &.{ fb_dir, "order.txt" });
        if (cwd.readFileAlloc(io, order_path, arena, .limited(64 * 1024))) |order| {
            var it = std.mem.tokenizeAny(u8, order, "\r\n");
            while (it.next()) |name| {
                try fallbacks.append(arena, try std.fs.path.join(arena, &.{ fb_dir, std.mem.trim(u8, name, " ") }));
            }
        } else |_| {}

        var variable: std.ArrayList([]const u8) = .empty;
        const var_dir = try std.fs.path.join(arena, &.{ p, "..", "fonts-variable" });
        if (cwd.openDir(io, var_dir, .{
            .iterate = true,
        })) |vd_const| {
            var vd = vd_const;
            defer vd.close(io);
            var it = vd.iterate();
            while (try it.next(io)) |e| {
                if (e.kind != .file or !engine.fonts.isFontFile(e.name)) continue;
                try variable.append(arena, try std.fs.path.join(arena, &.{ var_dir, e.name }));
            }
        } else |_| {}
        return .{
            .faces = faces.items,
            .fallbacks = fallbacks.items,
            .variable = variable.items,
            .root = p,
        };
    }
    return .{};
}

fn listFontDir(io: Io, arena: std.mem.Allocator, path: []const u8, out: *std.ArrayList([]const u8), depth: u8) !void {
    var fd = Dir.cwd().openDir(io, path, .{
        .iterate = true,
    }) catch return;
    defer fd.close(io);
    var it = fd.iterate();
    while (try it.next(io)) |e| {
        if (e.kind == .directory) {
            if (depth < 2) try listFontDir(io, arena, try std.fs.path.join(arena, &.{ path, e.name }), out, depth + 1);
            continue;
        }
        if (e.kind != .file or !engine.fonts.isFontFile(e.name)) continue;
        try out.append(arena, try std.fs.path.join(arena, &.{ path, e.name }));
    }
}

/// Reads and adds every font `fontFiles` finds for the document in `dir`.
fn loadFonts(io: Io, gpa: std.mem.Allocator, dir: []const u8, loaded: *Loaded) !void {
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    const files = try fontFiles(io, scratch.allocator(), dir);
    const a = loaded.font_arena.allocator();
    const lists = [_][]const []const u8{ files.faces, files.fallbacks, files.variable };
    const roles = [_]engine.fonts.Role{ .face, .fallback, .variable };
    for (lists, roles) |list, role| for (list) |fp| {
        const bytes = Dir.cwd().readFileAlloc(io, fp, a, .limited(64 * 1024 * 1024)) catch continue;
        _ = try engine.fonts.add(&loaded.fonts, gpa, a, bytes, role);
    };
}

pub const LoadOptions = struct {
    /// Decodes the images too; layout needs only the fonts.
    images: bool = true,
};

/// Reads `<dir>/document.json` and decodes every asset it lists; unreadable assets are skipped.
pub fn load(io: Io, gpa: std.mem.Allocator, dir: []const u8, options: LoadOptions) !Loaded {
    const cwd = Dir.cwd();
    const doc_path = try std.fs.path.join(gpa, &.{ dir, "document.json" });
    defer gpa.free(doc_path);
    const json = try cwd.readFileAlloc(io, doc_path, gpa, .limited(max_file));
    defer gpa.free(json);
    var doc = try engine.pubd_read.fromJson(gpa, json, .{});
    errdefer doc.deinit();
    // A document kept page by page: every page's file, read into the document.
    for (doc.chunks, doc.pages) |ch, *pg| {
        const pp = try std.fs.path.join(gpa, &.{ dir, ch.src });
        defer gpa.free(pp);
        const pj = try cwd.readFileAlloc(io, pp, gpa, .limited(max_file));
        defer gpa.free(pj);
        pg.* = try engine.pubd_read.pageFromJson(gpa, doc.arena.allocator(), pj, .{});
    }
    // Bound fields as their variables say (a reader's part, pubd/SPEC.md "Variables").
    _ = try engine.pubd_vars.resolveDocument(gpa, &doc);
    var images: engine.render.Images = .empty;
    errdefer images.deinit(gpa);
    for (doc.assets) |asset| {
        if (!options.images) break;
        const p = try std.fs.path.join(gpa, &.{ dir, "assets", asset.hash });
        defer gpa.free(p);
        const bytes = cwd.readFileAlloc(io, p, gpa, .limited(max_file)) catch continue;
        defer gpa.free(bytes);
        var img = decodeImage(gpa, bytes) catch continue;
        defer img.deinit(gpa);
        const mip = try engine.pixmap.Mipmap.init(gpa, &img);
        try images.put(gpa, asset.hash, mip);
    }
    var loaded: Loaded = .{
        .doc = doc,
        .images = images,
        .font_arena = .init(gpa),
    };
    try loadFonts(io, gpa, dir, &loaded);
    return loaded;
}

/// Decodes a PNG or JPEG.
pub const decodeImage = engine.session.decodeImage;

/// The node with `id` anywhere under `nodes`, depth first.
pub fn findNode(nodes: []const m.Node, id: []const u8) ?*const m.Node {
    for (nodes) |*n| {
        if (std.mem.eql(u8, n.id, id)) return n;
        if (findNode(n.children, id)) |f| return f;
    }
    return null;
}
