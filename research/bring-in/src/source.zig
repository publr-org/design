//! A source design file read page by page: a `.fig` through the engine's importer (its
//! canvas only, never its images), or a `.pubd` folder through the Pubd reader. What
//! the file declares (styles, variables) is read up front; each page is built when asked
//! for and dropped by the caller.

const std = @import("std");
const engine = @import("publr_engine");
const figfile = @import("figfile.zig");

const m = engine.model;
const Io = std.Io;
const Dir = std.Io.Dir;

const max_file = 1024 * 1024 * 1024;

pub const Source = struct {
    gpa: std.mem.Allocator,
    io: Io,
    arena: std.heap.ArenaAllocator,
    path: []const u8,
    kind: enum {
        fig,
        pubd,
    },
    name: []const u8 = "",
    page_names: []const []const u8 = &.{},
    styles: []m.Style = &.{},
    collections: []m.Collection = &.{},
    variables: []m.Variable = &.{},
    glyphs: []const []const u8 = &.{},
    im: ?*engine.fig.Importer = null,
    doc: ?m.Document = null,
    /// The variables and collections by id (and library key).
    ix: engine.pubd_vars.Index = .{},

    pub fn open(io: Io, gpa: std.mem.Allocator, path: []const u8) !*Source {
        const self = try gpa.create(Source);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .io = io,
            .arena = .init(gpa),
            .path = path,
            .kind = if (std.mem.endsWith(u8, path, ".fig")) .fig else .pubd,
        };
        const a = self.arena.allocator();
        switch (self.kind) {
            .fig => {
                var tmp: std.heap.ArenaAllocator = .init(gpa);
                defer tmp.deinit();
                const c = try figfile.read(io, tmp.allocator(), path);
                const im = try engine.fig.Importer.create(gpa, c.canvas, c.meta);
                self.im = im;
                self.name = im.name;
                self.styles = im.styles;
                self.collections = im.collections;
                self.variables = im.variables;
                self.glyphs = im.glyphs();
                const names = try a.alloc([]const u8, im.page_guids.len);
                // Page names: built heads would cost a page build each; the importer's
                // own record has the name.
                for (names, 0..) |*n, i| n.* = try a.dupe(u8, try pageName(im, gpa, i));
                self.page_names = names;
            },
            .pubd => {
                const doc_path = try std.fs.path.join(a, &.{ path, "document.json" });
                const json = try Dir.cwd().readFileAlloc(io, doc_path, gpa, .limited(max_file));
                defer gpa.free(json);
                self.doc = try engine.pubd_read.fromJson(gpa, json, .{});
                const d = &self.doc.?;
                self.name = d.name;
                self.styles = d.styles;
                self.collections = d.collections;
                self.variables = d.variables;
                self.glyphs = d.glyphs;
                const names = try a.alloc([]const u8, d.pages.len);
                for (names, d.pages) |*n, p| n.* = p.name;
                self.page_names = names;
            },
        }
        self.ix = try .fromLists(gpa, self.collections, self.variables);
        return self;
    }

    pub fn deinit(self: *Source) void {
        self.ix.deinit(self.gpa);
        if (self.im) |im| im.destroy();
        if (self.doc) |*d| d.deinit();
        self.arena.deinit();
        self.gpa.destroy(self);
    }

    pub fn pageCount(self: *const Source) usize {
        return self.page_names.len;
    }

    /// Page `i` with all its nodes, built in `a`.
    pub fn page(self: *Source, a: std.mem.Allocator, i: usize) !m.Node {
        switch (self.kind) {
            .fig => return self.im.?.page(a, i),
            .pubd => {
                const d = &self.doc.?;
                if (d.chunks.len != d.pages.len or d.pages.len == 0) return d.pages[i];
                const pp = try std.fs.path.join(a, &.{ self.path, d.chunks[i].src });
                const pj = try Dir.cwd().readFileAlloc(self.io, pp, self.gpa, .limited(max_file));
                defer self.gpa.free(pj);
                return engine.pubd_read.pageFromJson(self.gpa, a, pj, .{});
            },
        }
    }

    pub fn style(self: *const Source, id: []const u8) ?*const m.Style {
        for (self.styles) |*s| if (std.mem.eql(u8, s.id, id)) return s;
        return null;
    }

    /// The variable a reference names: its id, or `key:<library key>`.
    pub fn variable(self: *const Source, ref: []const u8) ?*const m.Variable {
        return self.ix.lookup(ref);
    }

    pub fn collection(self: *const Source, id: []const u8) ?*const m.Collection {
        return self.ix.cols.get(id);
    }
};

fn pageName(im: *engine.fig.Importer, gpa: std.mem.Allocator, i: usize) ![]const u8 {
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    const g = im.page_guids[i];
    const rec = im.ctx.nodes.get(g) orelse return "";
    const v: engine.kiwi.View = .{
        .s = im.ctx.s,
        .v = try engine.kiwi.decodeAt(scratch.allocator(), im.ctx.s, im.ctx.node_def, im.data, rec.at),
    };
    // The name points into the scratch's decode or into the message bytes; copied by
    // the caller before the scratch goes.
    const name = v.getStr("name") orelse "";
    return im.arena.allocator().dupe(u8, name);
}
