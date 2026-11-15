//! Importing a `.fig` that may be far larger than memory: the canvas (the document,
//! small) is decoded whole, images come in one at a time and leave as soon as they are
//! hashed, and the Pubd goes out page by page (`pages/<file>.json`, then
//! `document.json`), each page built, written and dropped before the next. What stays is
//! the decoded canvas and a list of assets; never the images together, never two pages.
//!
//! The host reads the zip (`container.findDirectory`, `listDirectory`, `dataStart`) and
//! drives: `create` with `canvas.fig` and `meta.json`, `addImage` for each
//! `images/<ref>`, `pageJson` for each page, `documentJson` last.

const std = @import("std");
const m = @import("../../pubd/model.zig");
const write = @import("../../pubd/write.zig");
const figma = @import("../figma.zig");
const sniff = @import("../../codec/sniff.zig").sniff;
const pages_mod = @import("../pages.zig");
const fig = @import("fig.zig");

pub const Job = struct {
    gpa: std.mem.Allocator,
    im: *fig.Importer,
    /// The job's own lists (assets, page heads, chunks).
    arena: std.heap.ArenaAllocator,
    /// Image ref (the zip's name) to asset, for every image added.
    by_ref: std.StringHashMapUnmanaged(m.Asset) = .empty,
    heads: std.ArrayList(m.Node) = .empty,
    chunks: std.ArrayList(m.PageChunk) = .empty,
    /// Pattern sources pages use from elsewhere (ids).
    foreign: std.ArrayList([]const u8) = .empty,
    /// The fonts the pages ask for.
    fonts: std.ArrayList(m.FontRef) = .empty,
    /// The components and component sets of the pages written so far.
    components: std.ArrayList(m.ComponentRef) = .empty,

    pub fn create(gpa: std.mem.Allocator, canvas: []const u8, meta: ?[]const u8) !*Job {
        const self = try gpa.create(Job);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .im = try fig.Importer.create(gpa, canvas, meta),
            .arena = .init(gpa),
        };
        return self;
    }

    pub fn destroy(self: *Job) void {
        self.by_ref.deinit(self.gpa);
        self.heads.deinit(self.gpa);
        self.chunks.deinit(self.gpa);
        self.fonts.deinit(self.gpa);
        self.im.destroy();
        self.arena.deinit();
        const gpa = self.gpa;
        gpa.destroy(self);
    }

    pub fn pageCount(self: *const Job) usize {
        return self.im.page_guids.len;
    }

    /// Takes in the bytes of `images/<ref>`: answers the asset's hash (SHA-256, lowercase
    /// hex, in the job's memory), the name its file gets. The bytes are not kept.
    pub fn addImage(self: *Job, ref: []const u8, bytes: []const u8) ![]const u8 {
        if (self.by_ref.get(ref)) |a| return a.hash;
        const a = self.arena.allocator();
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        const hex = std.fmt.bytesToHex(digest, .lower);
        const kind = sniff(bytes);
        const asset: m.Asset = .{
            .hash = try a.dupe(u8, &hex),
            .type = kind.type,
            .width = kind.width,
            .height = kind.height,
        };
        try self.by_ref.put(self.gpa, try a.dupe(u8, ref), asset);
        return asset.hash;
    }

    /// Page `i`'s file: its path (in the job's memory) and its JSON (the caller's, `gpa`).
    /// The page is built in scratch memory and dropped before this returns.
    pub fn pageJson(self: *Job, gpa: std.mem.Allocator, i: usize) !struct {
        path: []const u8,
        json: []u8,
    } {
        var scratch: std.heap.ArenaAllocator = .init(self.gpa);
        defer scratch.deinit();
        const sa = scratch.allocator();
        var page = try self.im.page(sa, i);
        self.resolve(&page);
        const a = self.arena.allocator();
        try self.heads.append(self.gpa, try pages_mod.headOf(a, &page));
        const chunk = try pages_mod.chunkOf(a, &page);
        try self.chunks.append(self.gpa, chunk);
        try pages_mod.foreignSources(a, &page, &page, &self.foreign);
        try pages_mod.componentsOf(a, &page, &self.components);
        var used: std.ArrayList(m.FontRef) = .empty;
        try m.collectFonts(sa, &page, &used);
        for (used.items) |f| {
            for (self.fonts.items) |x| {
                if (std.mem.eql(u8, x.family, f.family) and std.mem.eql(u8, x.style, f.style)) break;
            } else try self.fonts.append(self.gpa, try m.deepCopy(a, f));
        }
        return .{
            .path = chunk.src,
            .json = try write.pageJson(gpa, &page),
        };
    }

    /// Image refs to hashes in a node built from the file.
    fn resolve(self: *Job, n: *m.Node) void {
        for ([_][]m.Paint{ n.fills, n.strokes }) |list| for (list) |*p| self.resolvePaint(p);
        if (n.text) |t| for (t.runs) |r| if (r.fills) |fs| for (fs) |*p| self.resolvePaint(p);
        for (n.children) |*c| self.resolve(c);
    }

    fn resolvePaint(self: *Job, p: *m.Paint) void {
        if (p.kind != .image) return;
        if (self.by_ref.get(p.asset)) |a| p.asset = a.hash;
    }

    /// `document.json`, once every page is out: the name, the pages' own fields and
    /// files, the styles, the assets the pages use, and the nodes pages share. The
    /// caller's (`gpa`).
    pub fn documentJson(self: *Job, gpa: std.mem.Allocator) ![]u8 {
        var scratch: std.heap.ArenaAllocator = .init(self.gpa);
        defer scratch.deinit();
        const sa = scratch.allocator();
        var assets: std.ArrayList(m.Asset) = .empty;
        for (self.im.images()) |ref| {
            const a = self.by_ref.get(ref.ref) orelse continue;
            try assets.append(sa, a);
        }
        var shared: std.ArrayList(m.Node) = .empty;
        for (self.foreign.items) |id| {
            var n = (try self.im.nodeById(sa, id)) orelse continue;
            self.resolve(&n);
            try shared.append(sa, n);
        }
        // The shared nodes' own images.
        for (self.im.images()) |ref| {
            const a = self.by_ref.get(ref.ref) orelse continue;
            for (assets.items) |x| {
                if (std.mem.eql(u8, x.hash, a.hash)) break;
            } else try assets.append(sa, a);
        }
        const doc: m.Document = .{
            .arena = undefined,
            .name = self.im.name,
            .pages = self.heads.items,
            .chunks = self.chunks.items,
            .styles = self.im.styles,
            .assets = assets.items,
            .shared = shared.items,
            .glyphs = self.im.glyphs(),
            .fonts = self.fonts.items,
            .collections = self.im.collections,
            .variables = self.im.variables,
            .components = self.components.items,
        };
        return write.toJson(gpa, &doc);
    }

    /// Node types left out, with counts.
    pub fn skipped(self: *Job) ![]fig.Skipped {
        return self.im.skippedList(self.arena.allocator());
    }
};
