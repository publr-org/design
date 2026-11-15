//! Figma's `.fig` file to a Pubd document: the same model `figma.zig` makes from the REST
//! API, read from the file itself (docs/fig-format.md).
//!
//! Built from files we made ourselves, the public Kiwi format and Figma's public API
//! documentation; every mapping below was checked against the REST answer for the same
//! nodes. Where REST and the file disagree on a default, this follows REST, so both
//! importers make the same document.

const std = @import("std");
const m = @import("../../pubd/model.zig");
const write = @import("../../pubd/write.zig");
const geom = @import("../../raster/geom.zig");
const figma = @import("../figma.zig");
const kiwi = @import("kiwi.zig");
const blobs = @import("blobs.zig");
const container = @import("container.zig");
const layout = @import("../../layout/layout.zig");
const pubd_vars = @import("../../pubd/vars.zig");

const View = kiwi.View;
const Vec2 = geom.Vec2;

pub const Error = container.Error || kiwi.Error || blobs.Error || error{
    /// The zip has no `canvas.fig`, or the canvas lacks a schema or a message.
    NotAFigFile,
    /// The schema has no `Message` or the message no document.
    BadDocument,
};

pub const Result = struct {
    doc: m.Document,
    /// Every image the document uses, in first-use order, by the file's name for it
    /// (`images/<ref>` in the zip; the same as REST's `imageRef`). Image paints carry the
    /// ref as `asset` until `figma.resolveImages` swaps in hashes.
    images: []figma.ImageRef,
    /// The bytes of each of `images` (same order), empty when the zip lacks the file.
    image_bytes: [][]const u8,
    /// Node types the importer left out, with how many of each (`BRUSH`, `VARIABLE`, …).
    skipped: []Skipped,
    /// The canvas format version (the u32 after the magic).
    version: u32,
};

pub const Skipped = struct {
    type: []const u8,
    count: u32,
};

/// Reads a `.fig` (a zip, or a bare `canvas.fig`) and builds the document. Everything
/// lives in the document's arena. For files too large to hold whole, `Importer` builds
/// one page at a time from the canvas alone.
pub fn import(gpa: std.mem.Allocator, bytes: []const u8) Error!Result {
    var doc: m.Document = .{
        .arena = .init(gpa),
    };
    errdefer doc.deinit();
    const a = doc.arena.allocator();

    var canvas_bytes: []const u8 = bytes;
    var meta: ?[]const u8 = null;
    var entries: []container.Entry = &.{};
    if (std.mem.startsWith(u8, bytes, "PK")) {
        entries = try container.zipEntries(a, bytes);
        canvas_bytes = for (entries) |e| {
            if (std.mem.eql(u8, e.name, "canvas.fig")) break try container.entryBytes(a, e);
        } else return error.NotAFigFile;
        for (entries) |e| if (std.mem.eql(u8, e.name, "meta.json")) {
            meta = try container.entryBytes(a, e);
        };
    }
    const im = try Importer.create(gpa, canvas_bytes, meta);
    defer im.destroy();
    doc.name = try a.dupe(u8, im.name);
    // Built in scratch memory and copied: a built node's strings point into the
    // importer's message bytes, which go with it.
    const pages = try a.alloc(m.Node, im.page_guids.len);
    for (pages, 0..) |*pg, i| {
        var scratch: std.heap.ArenaAllocator = .init(gpa);
        defer scratch.deinit();
        pg.* = try m.deepCopy(a, try im.page(scratch.allocator(), i));
    }
    doc.pages = pages;
    doc.styles = try m.deepCopy(a, im.styles);
    doc.collections = try m.deepCopy(a, im.collections);
    doc.variables = try m.deepCopy(a, im.variables);
    doc.glyphs = try m.deepCopy(a, im.glyphs());

    // The image files, by name.
    const images = try m.deepCopy(a, im.ctx.images.items);
    const image_bytes = try a.alloc([]const u8, images.len);
    for (images, image_bytes) |ref, *out| {
        out.* = &.{};
        for (entries) |e| {
            if (!std.mem.startsWith(u8, e.name, "images/")) continue;
            if (!std.mem.eql(u8, e.name["images/".len..], ref.ref)) continue;
            out.* = try container.entryBytes(a, e);
            break;
        }
    }
    return .{
        .doc = doc,
        .images = images,
        .image_bytes = image_bytes,
        .skipped = try im.skippedList(a),
        .version = im.version,
    };
}

/// A `.fig` canvas decoded and indexed, built into pages one at a time (`page`), each in
/// memory of the caller's choosing, so a page can be written out and dropped before the
/// next is built. The file's nodes stay as Kiwi values, small next to the pages that
/// instances expand them into.
pub const Importer = struct {
    arena: std.heap.ArenaAllocator,
    ctx: Ctx,
    /// The file's name from `meta.json` ("" without one).
    name: []const u8 = "",
    /// The canvas format version (the u32 after the magic).
    version: u32 = 0,
    /// The pages in order, by guid.
    page_guids: []const u64 = &.{},
    styles: []m.Style = &.{},
    /// Variable collections and variables (from the internal page).
    collections: []m.Collection = &.{},
    variables: []m.Variable = &.{},
    /// The message's bytes (the importer's), and where each node's record starts in them.
    data: []u8 = &.{},
    offsets: []const u32 = &.{},
    /// Image refs the file names (`namesImage`), gathered on first ask.
    named: ?std.StringHashMapUnmanaged(void) = null,
    /// The variables by id, for resolving bound fields of the pages built.
    var_index: ?pubd_vars.Index = null,
    /// Nodes of the pages built so far whose bound fields the variables changed (the
    /// file's copies were stale).
    resolved: u64 = 0,

    /// Decodes `canvas.fig` (and reads the name from `meta.json` when given). Copies what
    /// it keeps: the caller may free both after.
    pub fn create(gpa: std.mem.Allocator, canvas_bytes: []const u8, meta_json: ?[]const u8) Error!*Importer {
        const self = try gpa.create(Importer);
        errdefer gpa.destroy(self);
        self.* = .{
            .arena = .init(gpa),
            .ctx = undefined,
        };
        errdefer self.arena.deinit();
        const a = self.arena.allocator();
        if (meta_json) |mj| self.name = try a.dupe(u8, metaName(a, mj) orelse "");
        const canvas = try container.canvasChunks(a, canvas_bytes);
        if (canvas.chunks.len < 2) return error.NotAFigFile;
        self.version = canvas.version;
        const schema = try a.create(kiwi.Schema);
        schema.* = try kiwi.parseSchema(a, try container.unpackChunk(a, canvas.chunks[0]));
        // The message stays as bytes, unpacked into a block of its own; node records are
        // decoded from it when a page needs them.
        self.data = try container.unpackChunk(gpa, canvas.chunks[1]);
        errdefer gpa.free(self.data);
        const data = self.data;
        const root_def = schema.find("Message") orelse return error.BadDocument;
        self.ctx = .{
            .a = a,
            .keep = a,
            .s = schema,
            .data = data,
        };
        const ctx = &self.ctx;

        // Where each node's record starts, and the blobs (pointers into the bytes).
        var offsets: []u32 = &.{};
        var r: kiwi.Reader = .{
            .bytes = data,
        };
        const md = &schema.defs[root_def];
        while (true) {
            const id = try r.varUint();
            if (id == 0) break;
            const fi = md.fieldById(id) orelse return error.UnknownField;
            const f = md.fields[fi];
            if (std.mem.eql(u8, f.name, "nodeChanges") and f.is_array and f.type == .def) {
                const n = try r.varUint();
                if (n > r.remaining()) return error.Truncated;
                ctx.node_def = f.type.def;
                offsets = try a.alloc(u32, n);
                for (offsets) |*o| {
                    o.* = @intCast(r.at);
                    try kiwi.skip(schema, f.type, &r);
                }
            } else if (std.mem.eql(u8, f.name, "blobs")) {
                const list = try kiwi.decodeField(a, schema, f, &r);
                const items: kiwi.Items = .{
                    .s = schema,
                    .items = if (list == .array) list.array else &.{},
                };
                const bl = try a.alloc([]const u8, items.len());
                for (bl, 0..) |*b, k| b.* = if (items.at(k).get("bytes")) |x| x.bytes() orelse &.{} else &.{};
                ctx.blobs = bl;
            } else try kiwi.skipField(schema, f, &r);
        }
        self.offsets = offsets;

        // Index the nodes and hang children on their parents, a record at a time.
        var scratch: std.heap.ArenaAllocator = .init(gpa);
        defer scratch.deinit();
        var doc_guid: ?u64 = null;
        for (offsets) |at| {
            _ = scratch.reset(.retain_capacity);
            const v = try ctx.decode(scratch.allocator(), at);
            const g = guidOf(v.get("guid")) orelse continue;
            try ctx.nodes.put(a, g, .{
                .at = at,
            });
            if (v.fieldIs("type", "VARIABLE") or v.fieldIs("type", "VARIABLE_SET")) {
                if (v.getStr("key")) |k| if (k.len > 0) {
                    try ctx.var_keys.put(a, try a.dupe(u8, k), g);
                    // A library variable copied in more than once (one per version the
                    // file used): references name the version too.
                    if (v.getStr("version")) |ver| try ctx.var_versions.put(a, try std.fmt.allocPrint(a, "{s}@{s}", .{ k, ver }), g);
                };
            }
            if (v.get("styleType") != null) {
                if (v.getStr("key")) |k| if (k.len > 0) try ctx.style_keys.put(a, try a.dupe(u8, k), g);
            }
            if (v.fieldIs("type", "DOCUMENT") and doc_guid == null) doc_guid = g;
        }
        for (offsets) |at| {
            _ = scratch.reset(.retain_capacity);
            const v = try ctx.decode(scratch.allocator(), at);
            const g = guidOf(v.get("guid")) orelse continue;
            const pi = v.get("parentIndex") orelse continue;
            const p = guidOf(pi.get("guid")) orelse continue;
            const rec = ctx.nodes.getPtr(p) orelse continue;
            try rec.children.append(a, .{
                .guid = g,
                // Points into the message bytes, which stay.
                .position = pi.getStr("position") orelse "",
            });
        }
        var it = ctx.nodes.valueIterator();
        while (it.next()) |rec| std.mem.sort(Child, rec.children.items, {}, Child.lessThan);

        _ = scratch.reset(.retain_capacity);
        ctx.cache_a = scratch.allocator();
        defer ctx.dropCache(a);
        const top = ctx.nodes.get(doc_guid orelse return error.BadDocument).?;
        var pages: std.ArrayList(u64) = .empty;
        var styles: std.ArrayList(m.Style) = .empty;
        var collections: std.ArrayList(m.Collection) = .empty;
        var variables: std.ArrayList(m.Variable) = .empty;
        for (top.children.items) |c| {
            const v = (try ctx.view(c.guid)).?;
            const rec = ctx.nodes.get(c.guid).?;
            if (!v.fieldIs("type", "CANVAS")) continue;
            if (v.getBool("internalOnly") orelse false) {
                // The internal page holds styles, variables and brushes, not drawn content.
                for (rec.children.items) |sc| try ctx.collectStyles(sc.guid, &styles);
                for (rec.children.items) |sc| try ctx.collectVariable(sc.guid, &collections, &variables);
                for (rec.children.items) |sc| try ctx.collectOverride(sc.guid, collections.items);
                // In the editor's order: by `sortPosition`; collections never moved by
                // name, as the editor lists them.
                std.mem.sort(m.Collection, collections.items, ctx, Ctx.collectionBefore);
                std.mem.sort(m.Variable, variables.items, ctx, Ctx.variableBefore);
                continue;
            }
            try pages.append(a, c.guid);
        }
        // Styles can also sit on ordinary pages.
        for (top.children.items) |c| {
            const v = (try ctx.view(c.guid)).?;
            if (!(v.getBool("internalOnly") orelse false)) try ctx.collectStyles(c.guid, &styles);
        }
        // In the editor's order: by `sortPosition`.
        std.mem.sort(m.Style, styles.items, ctx, Ctx.styleBefore);
        self.page_guids = pages.items;
        self.styles = styles.items;
        self.collections = collections.items;
        self.variables = variables.items;
        return self;
    }

    /// Debugging (`pe fig-dump`): writes, a JSON line each, the node records whose `type`
    /// is `filter` or that have a field named `filter` ("styleType"), every field by its
    /// name; long arrays and deep values cut short, blobs as their length.
    pub fn dump(self: *Importer, w: *std.Io.Writer, filter: []const u8) !void {
        var scratch: std.heap.ArenaAllocator = .init(self.arena.child_allocator);
        defer scratch.deinit();
        var it = self.ctx.nodes.iterator();
        while (it.next()) |e| {
            _ = scratch.reset(.retain_capacity);
            const v = try self.ctx.decode(scratch.allocator(), e.value_ptr.at);
            if (!(v.fieldIs("type", filter) or v.get(filter) != null)) continue;
            try dumpValue(w, self.ctx.s, v.v, 0);
            try w.writeByte('\n');
        }
    }

    pub fn destroy(self: *Importer) void {
        const gpa = self.arena.child_allocator;
        if (self.var_index) |*ix| ix.deinit(gpa);
        gpa.free(self.data);
        self.arena.deinit();
        gpa.destroy(self);
    }

    /// Builds node `src_guid` (with no instance around it) into `a`; the node records it
    /// reads are decoded in scratch memory, dropped after.
    fn building(self: *Importer, a: std.mem.Allocator, src_guid: u64) Error!?m.Node {
        var scratch: std.heap.ArenaAllocator = .init(self.arena.child_allocator);
        defer scratch.deinit();
        self.ctx.a = a;
        self.ctx.cache_a = scratch.allocator();
        defer {
            self.ctx.a = self.arena.allocator();
            self.ctx.dropCache(self.arena.allocator());
        }
        const v = (try self.ctx.view(src_guid)) orelse return null;
        return self.ctx.node(.{
            .base = v,
        }, null, 0, .{});
    }

    /// Builds page `i` in `a`. Its image paints name the file's images (`images/<ref>`)
    /// until `figma.resolveImagesIn` swaps in hashes; `images` lists them.
    pub fn page(self: *Importer, a: std.mem.Allocator, i: usize) Error!m.Node {
        var pg = (try self.building(a, self.page_guids[i])) orelse return error.BadDocument;
        // Bound fields take their variables' values in the modes the nodes are in (the
        // file's copies can be stale, as Figma's own render shows).
        if (self.variables.len > 0) {
            const gpa = self.arena.child_allocator;
            if (self.var_index == null) self.var_index = try pubd_vars.Index.fromLists(gpa, self.collections, self.variables);
            var stack: std.ArrayList(m.ModeChoice) = .empty;
            defer stack.deinit(gpa);
            self.resolved += try pubd_vars.resolveTree(&self.var_index.?, gpa, a, &pg, &stack);
        }
        return pg;
    }

    /// Bindings the pages built so far hold (every bound field, any object).
    pub fn bindingCount(self: *const Importer) u64 {
        return self.ctx.bound;
    }

    /// Whether the file names image `ref` anywhere (a paint's `image.hash`, in any node,
    /// override or style): images the zip holds that nothing names need not be copied.
    pub fn namesImage(self: *Importer, ref: []const u8) !bool {
        if (self.named == null) {
            var set: std.StringHashMapUnmanaged(void) = .empty;
            var scratch: std.heap.ArenaAllocator = .init(self.arena.child_allocator);
            defer scratch.deinit();
            for (self.offsets) |at| {
                _ = scratch.reset(.retain_capacity);
                try self.collectNamed((try self.ctx.decode(scratch.allocator(), at)).v, &set);
            }
            self.named = set;
        }
        return self.named.?.contains(ref);
    }

    fn collectNamed(self: *Importer, v: kiwi.Value, set: *std.StringHashMapUnmanaged(void)) !void {
        switch (v) {
            .array => |arr| for (arr) |x| try self.collectNamed(x, set),
            .record => |r| {
                const df = &self.ctx.s.defs[r.def];
                for (r.entries) |e| {
                    if (std.mem.eql(u8, df.fields[e.field].name, "image")) {
                        const iv: View = .{
                            .s = self.ctx.s,
                            .v = e.value,
                        };
                        if (iv.get("hash")) |h| if (h.bytes()) |hash| if (hash.len > 0 and hash.len <= 64) {
                            const a = self.arena.allocator();
                            const ref = try a.alloc(u8, hash.len * 2);
                            for (hash, 0..) |b, i| _ = std.fmt.bufPrint(ref[i * 2 ..][0..2], "{x:0>2}", .{b}) catch unreachable;
                            try set.put(a, ref, {});
                        };
                    }
                    try self.collectNamed(e.value, set);
                }
            },
            else => {},
        }
    }

    /// Node `id` built on its own in `a`: an id of the file (`<session>:<local>`), not
    /// one inside an instance; null when there is no such node.
    pub fn nodeById(self: *Importer, a: std.mem.Allocator, id: []const u8) Error!?m.Node {
        var it = std.mem.splitScalar(u8, id, ':');
        const sess = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch return null;
        const local = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch return null;
        return self.building(a, @as(u64, sess) << 32 | local);
    }

    /// The glyph outlines the texts built so far draw (`Text.glyphs` index them).
    pub fn glyphs(self: *Importer) []const []const u8 {
        return self.ctx.glyph_paths.items;
    }

    /// Every image the pages built so far use, in first-use order (in the importer's
    /// memory; `hash` is the ref until the caller sets it).
    pub fn images(self: *Importer) []figma.ImageRef {
        return self.ctx.images.items;
    }

    /// Node types left out so far, with counts, copied into `a`.
    pub fn skippedList(self: *Importer, a: std.mem.Allocator) ![]Skipped {
        var out: std.ArrayList(Skipped) = .empty;
        var sit = self.ctx.skipped.iterator();
        while (sit.next()) |e| try out.append(a, .{
            .type = try a.dupe(u8, e.key_ptr.*),
            .count = e.value_ptr.*,
        });
        return out.items;
    }
};

fn metaName(a: std.mem.Allocator, json: []const u8) ?[]const u8 {
    const v = std.json.parseFromSliceLeaky(std.json.Value, a, json, .{}) catch return null;
    if (v != .object) return null;
    const n = v.object.get("file_name") orelse return null;
    return if (n == .string) n.string else null;
}

/// A node's guid as one number: session id high, local id low.
fn guidOf(v: ?View) ?u64 {
    const g = v orelse return null;
    const s = g.getUint("sessionID") orelse return null;
    const l = g.getUint("localID") orelse return null;
    return @as(u64, s) << 32 | l;
}

/// The key overrides use for a node inside a component (`overrideKey`): a component
/// copied from a library keeps its children's original guids there, and instances name
/// those in their `guidPath`s. 0 (no node's guid) when it has none.
fn overrideKey(v: View) u64 {
    return guidOf(v.get("overrideKey")) orelse 0;
}

fn guidText(a: std.mem.Allocator, g: u64) ![]const u8 {
    return std.fmt.allocPrint(a, "{d}:{d}", .{ g >> 32, g & 0xffffffff });
}

const Child = struct {
    guid: u64,
    /// The fractional index that orders siblings (byte order, first is bottom-most).
    position: []const u8,

    fn lessThan(_: void, x: Child, y: Child) bool {
        return switch (std.mem.order(u8, x.position, y.position)) {
            .lt => true,
            .gt => false,
            .eq => x.guid < y.guid,
        };
    }
};

const Rec = struct {
    /// Where the node's record starts in the message bytes (`Ctx.view` reads it).
    at: u32,
    children: std.ArrayList(Child) = .empty,
};

/// A node's fields as seen through an instance: the node itself, then the overrides and
/// derived values that reach it (later layers win), then component properties.
const Src = struct {
    base: View,
    layers: []const View = &.{},
    /// Text from a text property.
    text: ?View = null,
    /// Visibility from a boolean property.
    visible: ?bool = null,
    /// The component an instance swap property picks.
    swap: ?u64 = null,
    /// For a swapped instance: the new component, whose look replaces the old one's
    /// (the node keeps its place: `placement` fields stay its own).
    swapped: ?View = null,

    /// Fields a swapped instance keeps from the node it replaces.
    const placement = [_][]const u8{
        "guid",                "parentIndex",             "type",                     "transform",
        "symbolData",          "derivedSymbolData",       "componentPropAssignments", "stackPositioning",
        "stackChildAlignSelf", "stackChildPrimaryGrow",   "horizontalConstraint",     "verticalConstraint",
        "visible",             "parameterConsumptionMap", "overriddenSymbolID",
    };

    fn get(self: Src, name: []const u8) ?View {
        var i = self.layers.len;
        while (i > 0) {
            i -= 1;
            if (self.layers[i].get(name)) |v| return v;
        }
        return self.own(name);
    }

    /// Field `name` of the node itself (for a swapped instance: of the new component,
    /// except its placement).
    fn own(self: Src, name: []const u8) ?View {
        if (self.swapped) |sw| {
            for (placement) |p| {
                if (std.mem.eql(u8, p, name)) return self.base.get(name);
            }
            return sw.get(name);
        }
        return self.base.get(name);
    }

    /// Field `name` read by `read` from the topmost layer where it reads as a value: a
    /// layer whose value is not finite (docs/fig-format.md) does not hide the next one.
    fn find(self: Src, comptime T: type, name: []const u8, read: fn (View) ?T) ?T {
        var i = self.layers.len;
        while (i > 0) {
            i -= 1;
            if (self.layers[i].get(name)) |v| if (read(v)) |x| return x;
        }
        return read(self.own(name) orelse return null);
    }

    fn float(self: Src, name: []const u8) ?f32 {
        return self.find(f32, name, View.float);
    }

    fn uint(self: Src, name: []const u8) ?u32 {
        return (self.get(name) orelse return null).uint();
    }

    fn boolean(self: Src, name: []const u8) ?bool {
        return (self.get(name) orelse return null).boolean();
    }

    fn str(self: Src, name: []const u8) ?[]const u8 {
        return (self.get(name) orelse return null).str();
    }

    fn enumName(self: Src, name: []const u8) ?[]const u8 {
        return (self.get(name) orelse return null).enumName();
    }

    fn is(self: Src, name: []const u8, value: []const u8) bool {
        return std.mem.eql(u8, self.enumName(name) orelse return false, value);
    }

    fn list(self: Src, name: []const u8) kiwi.Items {
        const f = self.get(name) orelse return .{
            .s = self.base.s,
            .items = &.{},
        };
        return .{
            .s = self.base.s,
            .items = if (f.v == .array) f.v.array else &.{},
        };
    }
};

/// One override or derived record and the instance path (guids) it applies to.
const Ov = struct {
    path: []const u64,
    rec: View,
};

/// Inside an instance: the id prefix of its expanded nodes, the overrides that reach into
/// it (paths relative to it), and its component property values.
const Scope = struct {
    prefix: []const u8,
    ovs: []const Ov,
    props: kiwi.Items,
};

/// Instances inside instances deeper than this are left empty (a cycle is corrupt).
const max_instance_depth = 16;

const Ctx = struct {
    /// Where the nodes being built go.
    a: std.mem.Allocator,
    /// The importer's own memory: the image and skipped lists.
    keep: std.mem.Allocator,
    s: *const kiwi.Schema,
    blobs: []const []const u8 = &.{},
    nodes: std.AutoHashMapUnmanaged(u64, Rec) = .empty,
    /// The message bytes and the type of its node records.
    data: []const u8 = &.{},
    node_def: u32 = 0,
    /// Node records decoded so far for what is being built, in `cache_a` (scratch,
    /// dropped after): a file's records are read when needed, never all at once.
    cache: std.AutoHashMapUnmanaged(u64, View) = .empty,
    cache_a: std.mem.Allocator = undefined,

    images: std.ArrayList(figma.ImageRef) = .empty,
    skipped: std.StringArrayHashMapUnmanaged(u32) = .empty,
    /// Glyph outlines texts use (`derivedTextData`), SVG path data in ems, by first use;
    /// `glyph_ids` maps a commands blob to its index here.
    glyph_paths: std.ArrayList([]const u8) = .empty,
    glyph_ids: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    /// Variables and variable sets by their library key (`key`), for values bound to a
    /// library's variable (`assetRef`).
    var_keys: std.StringHashMapUnmanaged(u64) = .empty,
    /// Each collection's and variable's `sortPosition` by its id (the order the editor
    /// lists them in; none for a collection never moved).
    sort_pos: std.StringHashMapUnmanaged([]const u8) = .empty,
    /// The same by `<key>@<version>`.
    var_versions: std.StringHashMapUnmanaged(u64) = .empty,
    /// Styles by their library key (`key`): a node following a library's style names it
    /// by `assetRef { key }` instead of a guid.
    style_keys: std.StringHashMapUnmanaged(u64) = .empty,
    /// Variable modes the nodes being built sit in (`variableModeBySetMap` of them and
    /// their ancestors), innermost last: a collection's mode set here wins over its
    /// default.
    modes: std.ArrayList(Mode) = .empty,
    /// Bindings recorded on what was built (any object: node, paint, effect, ...).
    bound: u64 = 0,

    const Mode = struct {
        set: u64,
        mode: u64,
    };

    fn decode(ctx: *Ctx, a: std.mem.Allocator, at: u32) Error!View {
        return .{
            .s = ctx.s,
            .v = try kiwi.decodeAt(a, ctx.s, ctx.node_def, ctx.data, at),
        };
    }

    /// Node `g`'s record, decoded on first use.
    fn view(ctx: *Ctx, g: u64) Error!?View {
        if (ctx.cache.get(g)) |v| return v;
        const rec = ctx.nodes.get(g) orelse return null;
        const v = try ctx.decode(ctx.cache_a, rec.at);
        try ctx.cache.put(ctx.cache_a, g, v);
        return v;
    }

    /// Forgets the decoded records (their memory is the scratch's owner's to free).
    fn dropCache(ctx: *Ctx, a: std.mem.Allocator) void {
        ctx.cache = .empty;
        ctx.cache_a = a;
    }

    /// A style's own value as Pubd JSON: its paints, its text settings or its effects
    /// (the panel's swatches and "20/Auto" read it). Layout guides keep none: their
    /// stretch values depend on the frame they are applied to.
    fn styleValue(ctx: *Ctx, v: View, kind: m.StyleKind) !?[]const u8 {
        const value: write.StyleValue = switch (kind) {
            .fill => .{
                .fill = if (v.get("fillPaints") != null) try ctx.paints(v.list("fillPaints")) else &.{},
            },
            .text => blk: {
                var ts = textStyle(.{
                    .base = v,
                });
                ts.vars = try ctx.bindingsOf(.{
                    .base = v,
                }, .text);
                break :blk .{
                    .text = ts,
                };
            },
            .effect => .{
                .effect = if (v.get("effects") != null) try ctx.effects(v.list("effects")) else &.{},
            },
            .grid => blk: {
                // A stretch guide's column size depends on the frame it is applied to:
                // the style keeps none (0).
                const gs = try ctx.grids(v.list("layoutGrids"), .{});
                for (gs) |*g| if (g.@"align" == .stretch) {
                    g.size = 0;
                };
                break :blk .{
                    .grid = gs,
                };
            },
        };
        return write.styleValueJson(ctx.a, value) catch |e| switch (e) {
            error.OutOfMemory, error.WriteFailed => error.OutOfMemory,
            // A value the file cannot hold (not a finite number): the style keeps none.
            else => null,
        };
    }

    fn collectStyles(ctx: *Ctx, g: u64, out: *std.ArrayList(m.Style)) !void {
        const rec = ctx.nodes.get(g) orelse return;
        const v = (try ctx.view(g)).?;
        if (v.getEnum("styleType")) |t| {
            const kind: ?m.StyleKind = if (std.mem.eql(u8, t, "FILL")) .fill else if (std.mem.eql(u8, t, "TEXT")) .text else if (std.mem.eql(u8, t, "EFFECT")) .effect else if (std.mem.eql(u8, t, "GRID")) .grid else null;
            const key = v.getStr("key") orelse "";
            if (kind) |k| try out.append(ctx.a, .{
                .id = try guidText(ctx.a, g),
                .kind = k,
                .name = v.getStr("name") orelse "",
                .description = v.getStr("description") orelse "",
                .value = try ctx.styleValue(v, k),
                // A library's style carries the key it is published under.
                .library = key.len > 0,
                .key = try ctx.a.dupe(u8, key),
                .deleted = v.getBool("isSoftDeleted") orelse false,
            });
            if (kind != null) try ctx.sort_pos.put(ctx.a, out.items[out.items.len - 1].id, try ctx.a.dupe(u8, v.getStr("sortPosition") orelse ""));
        }
        for (rec.children.items) |c| try ctx.collectStyles(c.guid, out);
    }

    /// A `VARIABLE_SET` (a collection and its modes) or a `VARIABLE` (its value in each
    /// mode; an alias kept as the id of the variable it names, or its library key when
    /// the file holds only that).
    fn collectVariable(ctx: *Ctx, g: u64, cols: *std.ArrayList(m.Collection), list: *std.ArrayList(m.Variable)) !void {
        const v = (try ctx.view(g)) orelse return;
        const a = ctx.a;
        if (v.fieldIs("type", "VARIABLE_SET")) {
            const ml = v.list("variableSetModes");
            var modes: std.ArrayList(m.VariableMode) = .empty;
            var order: std.ArrayList([]const u8) = .empty;
            var parent: ?[]const u8 = null;
            for (0..ml.len()) |i| {
                const md = ml.at(i);
                // An extended collection's mode names the parent collection and the
                // parent's mode it extends.
                var mode_parent: ?[]const u8 = null;
                if (md.get("parentModeId")) |pm| if (guidOf(pm)) |pg| {
                    mode_parent = try guidText(a, pg);
                };
                if (md.get("parentVariableSetId")) |ps| if (try ctx.setRef(ps)) |pid| {
                    parent = pid;
                };
                try modes.append(a, .{
                    .id = try guidText(a, guidOf(md.get("id")) orelse continue),
                    .name = try a.dupe(u8, md.getStr("name") orelse ""),
                    .parent = mode_parent,
                });
                try order.append(a, md.getStr("sortPosition") orelse "");
            }
            // By `sortPosition`: the first is the default.
            var i: usize = 1;
            while (i < modes.items.len) : (i += 1) {
                var j = i;
                while (j > 0 and std.mem.lessThan(u8, order.items[j], order.items[j - 1])) : (j -= 1) {
                    std.mem.swap(m.VariableMode, &modes.items[j], &modes.items[j - 1]);
                    std.mem.swap([]const u8, &order.items[j], &order.items[j - 1]);
                }
            }
            const cid = try guidText(a, g);
            try ctx.sort_pos.put(a, cid, try a.dupe(u8, v.getStr("sortPosition") orelse ""));
            try cols.append(a, .{
                .id = cid,
                .name = try a.dupe(u8, v.getStr("name") orelse ""),
                .modes = modes.items,
                .library = v.get("sourceLibraryKey") != null,
                .key = try a.dupe(u8, v.getStr("key") orelse ""),
                .hidden = !(v.getBool("isPublishable") orelse true),
                .parent = parent,
                .deleted = v.getBool("isSoftDeleted") orelse false,
            });
            return;
        }
        if (!v.fieldIs("type", "VARIABLE")) return;
        const set = (try ctx.setRef(v.get("variableSetID") orelse return)) orelse return;
        const rt = v.getEnum("variableResolvedType") orelse "COLOR";
        const vt: m.VariableType = if (std.mem.eql(u8, rt, "FLOAT")) .number else if (std.mem.eql(u8, rt, "STRING")) .string else if (std.mem.eql(u8, rt, "BOOLEAN")) .boolean else .color;
        var scopes: std.ArrayList([]const u8) = .empty;
        const sl = v.list("variableScopes");
        for (0..sl.len()) |i| {
            const name = sl.at(i).enumName() orelse continue;
            if (std.mem.eql(u8, name, "ALL_SCOPES")) continue;
            const low = try a.alloc(u8, name.len);
            for (name, low) |c, *o| o.* = if (c == '_') '-' else std.ascii.toLower(c);
            try scopes.append(a, low);
        }
        var code: m.CodeSyntax = .{};
        if (v.get("codeSyntax")) |c| {
            const entries = c.list("entries");
            for (0..entries.len()) |i| {
                const e = entries.at(i);
                const value = try a.dupe(u8, e.getStr("value") orelse "");
                const platform = e.getEnum("platform") orelse continue;
                if (std.mem.eql(u8, platform, "WEB")) code.web = value else if (std.mem.eql(u8, platform, "ANDROID")) code.android = value else if (std.ascii.eqlIgnoreCase(platform, "IOS")) code.ios = value;
            }
        }
        const vid = try guidText(a, g);
        try ctx.sort_pos.put(a, vid, try a.dupe(u8, v.getStr("sortPosition") orelse ""));
        try list.append(a, .{
            .id = vid,
            .name = try a.dupe(u8, v.getStr("name") orelse ""),
            .collection = set,
            .type = vt,
            .description = try a.dupe(u8, v.getStr("description") orelse ""),
            .values = try ctx.valuesOf(v),
            .scopes = scopes.items,
            .key = try a.dupe(u8, v.getStr("key") orelse ""),
            .hidden = !(v.getBool("isPublishable") orelse true),
            .deleted = v.getBool("isSoftDeleted") orelse false,
            .code = code,
        });
    }

    /// Collections by `sortPosition`, then by name (punctuation, digits, letters; case
    /// aside), then as read.
    fn collectionBefore(ctx: *Ctx, x: m.Collection, y: m.Collection) bool {
        switch (std.mem.order(u8, ctx.sort_pos.get(x.id) orelse "", ctx.sort_pos.get(y.id) orelse "")) {
            .lt => return true,
            .gt => return false,
            .eq => {},
        }
        const n = @min(x.name.len, y.name.len);
        for (x.name[0..n], y.name[0..n]) |a, b| {
            const ka = nameKey(a);
            const kb = nameKey(b);
            if (ka != kb) return ka < kb;
        }
        return x.name.len < y.name.len;
    }

    fn nameKey(c: u8) u16 {
        const class: u16 = if (std.ascii.isDigit(c)) 1 else if (std.ascii.isAlphabetic(c) or c >= 0x80) 2 else 0;
        return class << 8 | std.ascii.toLower(c);
    }

    /// Styles by `sortPosition`.
    fn styleBefore(ctx: *Ctx, x: m.Style, y: m.Style) bool {
        return std.mem.order(u8, ctx.sort_pos.get(x.id) orelse "", ctx.sort_pos.get(y.id) orelse "") == .lt;
    }

    /// Variables by `sortPosition` (each collection's own order), then as read.
    fn variableBefore(ctx: *Ctx, x: m.Variable, y: m.Variable) bool {
        return std.mem.order(u8, ctx.sort_pos.get(x.id) orelse "", ctx.sort_pos.get(y.id) orelse "") == .lt;
    }

    /// A `VARIABLE_OVERRIDE`: an extended collection's own values of one of its
    /// parent's variables, added to that collection.
    fn collectOverride(ctx: *Ctx, g: u64, cols: []m.Collection) !void {
        const v = (try ctx.view(g)) orelse return;
        if (!v.fieldIs("type", "VARIABLE_OVERRIDE")) return;
        const a = ctx.a;
        const set = (try ctx.setRef(v.get("variableSetID") orelse return)) orelse return;
        const target = (try ctx.aliasRef(v.get("overriddenVariableId"))) orelse return;
        for (cols) |*c| if (std.mem.eql(u8, c.id, set)) {
            const list = try a.alloc(m.VariableOverride, c.overrides.len + 1);
            @memcpy(list[0..c.overrides.len], c.overrides);
            list[c.overrides.len] = .{
                .variable = target,
                .values = try ctx.valuesOf(v),
            };
            c.overrides = list;
            return;
        };
    }

    /// A variable's (or override's) values by mode, as Pubd JSON.
    fn valuesOf(ctx: *Ctx, v: View) ![]m.VariableValue {
        const a = ctx.a;
        var values: std.ArrayList(m.VariableValue) = .empty;
        const entries = (v.get("variableDataValues") orelse return &.{}).list("entries");
        for (0..entries.len()) |i| {
            const e = entries.at(i);
            const mode = guidOf(e.get("modeID")) orelse continue;
            const val = (e.get("variableData") orelse continue).get("value") orelse continue;
            const json = (try ctx.valueJson(val, 0)) orelse continue;
            try values.append(a, .{
                .mode = try guidText(a, mode),
                .value = json,
            });
        }
        return values.items;
    }

    /// A variable value (`VariableAnyValue`) as Pubd JSON; null when it is none Pubd
    /// spells (or a colour channel is not a finite number).
    fn valueJson(ctx: *Ctx, val: View, depth: u32) error{OutOfMemory}!?[]const u8 {
        const a = ctx.a;
        if (depth > 8) return null;
        if (val.get("colorValue")) |c| return write.colorJson(a, color(c)) catch |err| switch (err) {
            error.OutOfMemory, error.WriteFailed => return error.OutOfMemory,
            else => return null,
        };
        if (val.getFloat("floatValue")) |f| {
            if (!std.math.isFinite(f)) return null;
            return try std.fmt.allocPrint(a, "{d}", .{f});
        }
        if (val.getStr("textValue")) |t| return try jsonString(a, t);
        if (val.getBool("boolValue")) |b| return if (b) "true" else "false";
        if (try ctx.aliasRef(val.get("alias"))) |id| return try std.fmt.allocPrint(a, "{{\"alias\":{s}}}", .{try jsonString(a, id)});
        // A colour whose opacity comes from a number (`COMPOSE_COLOR`: the colour, then
        // the opacity in percent).
        if (val.get("expressionValue")) |ex| if (std.mem.eql(u8, ex.getStr("expressionFunction") orelse ex.getEnum("expressionFunction") orelse "", "COMPOSE_COLOR")) {
            const args = ex.list("expressionArguments");
            if (args.len() < 2) return null;
            const c = (try ctx.valueJson(args.at(0).get("value") orelse return null, depth + 1)) orelse return null;
            const o = (try ctx.valueJson(args.at(1).get("value") orelse return null, depth + 1)) orelse return null;
            return try std.fmt.allocPrint(a, "{{\"compose\":{{\"color\":{s},\"opacity\":{s}}}}}", .{ c, o });
        };
        return null;
    }

    /// A collection's id from a `VariableSetID` (`{ guid }`, or a library's
    /// `{ assetRef { key } }` copied into the file).
    fn setRef(ctx: *Ctx, ref: View) !?[]const u8 {
        if (guidOf(ref.get("guid"))) |g| return try guidText(ctx.a, g);
        const ar = ref.get("assetRef") orelse return null;
        const key = ar.getStr("key") orelse return null;
        const g = ctx.keyed(ar) orelse return try std.fmt.allocPrint(ctx.a, "key:{s}", .{key});
        return try guidText(ctx.a, g);
    }

    /// The id of the variable an alias (`{ guid }` or a library's `{ assetRef { key } }`)
    /// names, when it is in the file.
    fn aliasId(ctx: *Ctx, alias: ?View) !?[]const u8 {
        const al = alias orelse return null;
        const g = guidOf(al.get("guid")) orelse ctx.keyed(al.get("assetRef") orelse return null) orelse return null;
        if (!ctx.nodes.contains(g)) return null;
        return try guidText(ctx.a, g);
    }

    /// How Pubd names the variable an alias names: its id, or `key:<library key>` for a
    /// library variable the file does not hold (a reader then keeps the field's value).
    fn aliasRef(ctx: *Ctx, alias: ?View) !?[]const u8 {
        const al = alias orelse return null;
        if (guidOf(al.get("guid"))) |g| return try guidText(ctx.a, g);
        const ar = al.get("assetRef") orelse return null;
        const key = ar.getStr("key") orelse return null;
        if (ctx.keyedVersion(ar)) |g| return try guidText(ctx.a, g);
        // A version of a library variable the file does not hold: the reference stays,
        // unresolved, and the field keeps the value Figma gave it.
        if (ar.getStr("version")) |ver| if (ctx.var_keys.contains(key)) return try std.fmt.allocPrint(ctx.a, "key:{s}@{s}", .{ key, ver });
        return try std.fmt.allocPrint(ctx.a, "key:{s}", .{key});
    }

    /// `keyed`, but a reference that names a version finds only that version.
    fn keyedVersion(ctx: *Ctx, ar: View) ?u64 {
        const key = ar.getStr("key") orelse return null;
        const ver = ar.getStr("version") orelse return ctx.var_keys.get(key);
        var buf: [256]u8 = undefined;
        const kv = std.fmt.bufPrint(&buf, "{s}@{s}", .{ key, ver }) catch return null;
        return ctx.var_versions.get(kv);
    }

    /// The node a library reference (`assetRef { key, version }`) names: the copy of
    /// that version, else the last copy with that key.
    fn keyed(ctx: *Ctx, ar: View) ?u64 {
        const key = ar.getStr("key") orelse return null;
        if (ar.getStr("version")) |ver| {
            var buf: [256]u8 = undefined;
            if (std.fmt.bufPrint(&buf, "{s}@{s}", .{ key, ver })) |kv| {
                if (ctx.var_versions.get(kv)) |g| return g;
            } else |_| {}
        }
        return ctx.var_keys.get(key);
    }

    /// The variable a binding (`VariableData`, as in `colorVar`) names, when it is an
    /// alias.
    fn bindingRef(ctx: *Ctx, data: ?View) !?[]const u8 {
        const val = (data orelse return null).get("value") orelse return null;
        if (val.get("alias")) |al| return ctx.aliasRef(al);
        // Inside an instance scaled as a whole Figma binds `MULTIPLY(scale, alias)`: the
        // scale is the instance's (Pubd `scale`, which resolving applies), the variable
        // the alias.
        if (val.get("expressionValue")) |ex| if (std.mem.eql(u8, ex.getStr("expressionFunction") orelse ex.getEnum("expressionFunction") orelse "", "MULTIPLY")) {
            const args = ex.list("expressionArguments");
            var alias: ?View = null;
            var constants: usize = 0;
            for (0..args.len()) |i| {
                const av = args.at(i).get("value") orelse return null;
                if (av.get("alias")) |al| {
                    if (alias != null) return null;
                    alias = al;
                } else if (av.getFloat("floatValue") != null) constants += 1 else return null;
            }
            if (constants == 1) if (alias) |al| return ctx.aliasRef(al);
        };
        return null;
    }

    /// Appends `{ key, ref }` when the binding `data` names a variable.
    fn bindTo(ctx: *Ctx, out: *std.ArrayList(m.VarBinding), key: []const u8, data: ?View) !void {
        const ref = (try ctx.bindingRef(data)) orelse return;
        for (out.items) |b| if (std.mem.eql(u8, b.key, key)) return;
        try out.append(ctx.a, .{
            .key = key,
            .variable = ref,
        });
        ctx.bound += 1;
    }

    const BindingSet = enum {
        /// The node's own fields (`vars` on the node).
        node,
        /// Its text style's (`vars` in `style`).
        text,
    };

    /// The variables a node's (or text run's, or style's) fields follow, by Pubd key:
    /// `parameterConsumptionMap` (and the older `variableConsumptionMap`, which files
    /// keep beside it) entries whose value is an alias.
    fn bindingsOf(ctx: *Ctx, src: Src, which: BindingSet) ![]m.VarBinding {
        var out: std.ArrayList(m.VarBinding) = .empty;
        // The topmost layer with a map of either kind gives the bindings (an override's
        // map replaces its main's). A swapped instance keeps the replaced node's map for
        // its component properties, but its fields, and the variables they follow, are
        // the new component's.
        const names = [_][]const u8{ "parameterConsumptionMap", "variableConsumptionMap" };
        var from: View = src.swapped orelse src.base;
        // The layer the maps come from: an override above it that sets a field itself,
        // with no binding of its own, gives the field that value.
        var map_layer: usize = 0;
        var k = src.layers.len;
        while (k > 0) {
            k -= 1;
            if (src.layers[k].get(names[0]) != null or src.layers[k].get(names[1]) != null) {
                from = src.layers[k];
                map_layer = k + 1;
                break;
            }
        }
        for (names) |name| {
            const map = from.get(name) orelse continue;
            const entries = map.list("entries");
            for (0..entries.len()) |i| {
                const e = entries.at(i);
                const field = e.getEnum("variableField") orelse continue;
                if (std.mem.eql(u8, field, "TEXT_DATA") and src.text != null) continue;
                if (std.mem.eql(u8, field, "VISIBLE") and src.visible != null) continue;
                if (setAbove(src, map_layer, field)) continue;
                const data = e.get("variableData");
                if (which == .text and std.mem.eql(u8, field, "FONT_STYLE")) {
                    // A font style is a string variable, or a weight (`asFloat`).
                    if (data) |d| if (d.get("value")) |val| if (val.get("fontStyleValue")) |fs| {
                        try ctx.bindTo(&out, "fontStyle", fs.get("asString"));
                        try ctx.bindTo(&out, "weight", fs.get("asFloat"));
                        continue;
                    };
                    try ctx.bindTo(&out, "fontStyle", data);
                    continue;
                }
                const key = (if (which == .node) nodeVarKey(field) else textVarKey(field)) orelse continue;
                try ctx.bindTo(&out, key, data);
            }
        }
        return out.items;
    }

    /// The auto layout a node gives its children; for a grid, its track ids in order.
    fn parentLayout(ctx: *Ctx, src: Src, l: ?m.Layout) !ParentLayout {
        const lay = l orelse return .{};
        if (lay.mode != .grid) return .{
            .mode = if (lay.mode == .horizontal) .horizontal else .vertical,
        };
        return .{
            .mode = .grid,
            .columns = try ctx.trackIds(src, "gridColumns"),
            .rows = try ctx.trackIds(src, "gridRows"),
        };
    }

    /// A grid's track ids (`entries[] { id, position }`), in position order.
    fn trackIds(ctx: *Ctx, src: Src, name: []const u8) ![]u64 {
        const entries = (src.get(name) orelse return &.{}).list("entries");
        const list = try ctx.a.alloc(Child, entries.len());
        for (list, 0..) |*c, i| c.* = .{
            .guid = guidOf(entries.at(i).get("id")) orelse 0,
            .position = entries.at(i).getStr("position") orelse "",
        };
        std.mem.sort(Child, list, {}, Child.lessThan);
        const ids = try ctx.a.alloc(u64, list.len);
        for (ids, list) |*o, c| o.* = c.guid;
        return ids;
    }

    /// A grid's tracks in order, each sized by its `…Sizing` entry (`trackSize.maxSizing`
    /// `{ type FIXED | FLEX | HUG, value }`; our files have the same minimum).
    fn tracks(ctx: *Ctx, src: Src, ids_name: []const u8, sizing_name: []const u8) ![]m.Track {
        const ids = try ctx.trackIds(src, ids_name);
        const sizing = (src.get(sizing_name) orelse return &.{}).list("entries");
        const out = try ctx.a.alloc(m.Track, ids.len);
        for (out, ids) |*t, id| {
            t.* = .{};
            for (0..sizing.len()) |i| {
                const e = sizing.at(i);
                if (guidOf(e.get("id")) != id) continue;
                const ms = e.path("trackSize.maxSizing") orelse break;
                const ty = ms.getEnum("type") orelse "FLEX";
                t.* = .{
                    .kind = if (std.mem.eql(u8, ty, "FIXED")) .fixed else if (std.mem.eql(u8, ty, "HUG")) .hug else .flex,
                    .value = ms.getFloat("value") orelse 1,
                };
                break;
            }
        }
        return out;
    }

    fn skip(ctx: *Ctx, t: []const u8) !void {
        const e = try ctx.skipped.getOrPut(ctx.keep, t);
        if (!e.found_existing) e.value_ptr.* = 0;
        e.value_ptr.* += 1;
    }

    /// The source of a child inside `scope`: its own record plus whatever the scope
    /// overrides on it, and the component properties it consumes.
    fn childSrc(ctx: *Ctx, record: View, g: u64, scope: ?*const Scope) !Src {
        var src: Src = .{
            .base = record,
        };
        const sc = scope orelse return src;
        var layers: std.ArrayList(View) = .empty;
        const key = overrideKey(record);
        for (sc.ovs) |ov| if (ov.path.len == 1 and (ov.path[0] == g or ov.path[0] == key)) try layers.append(ctx.a, ov.rec);
        src.layers = layers.items;
        // Component properties this node consumes.
        const pcm = src.get("parameterConsumptionMap");
        if (pcm) |p| {
            const entries = p.list("entries");
            for (0..entries.len()) |i| {
                const e = entries.at(i);
                const field = e.getEnum("variableField") orelse continue;
                const def = guidOf(e.path("variableData.value.propRefValue.defId")) orelse continue;
                applyProp(&src, sc.props, def, field);
            }
        }
        const refs = src.list("componentPropRefs");
        for (0..refs.len()) |i| {
            const r = refs.at(i);
            if (r.getBool("isDeleted") orelse false) continue;
            const field = r.getEnum("componentPropNodeField") orelse continue;
            const def = guidOf(r.get("defID")) orelse continue;
            applyProp(&src, sc.props, def, field);
        }
        return src;
    }

    /// The variable modes a node sets (`variableModeBySetMap`), by collection: an
    /// extended collection's mode under the extension's id.
    fn modesOf(ctx: *Ctx, src: Src) ![]m.ModeChoice {
        const vm = src.get("variableModeBySetMap") orelse return &.{};
        const entries = vm.list("entries");
        var out: std.ArrayList(m.ModeChoice) = .empty;
        for (0..entries.len()) |i| {
            const e = entries.at(i);
            const set_v = e.get("variableSetExtensionID") orelse e.get("variableSetID") orelse continue;
            const set = (try ctx.setRef(set_v)) orelse continue;
            const mode = guidOf(e.get("variableModeID")) orelse continue;
            try out.append(ctx.a, .{
                .collection = set,
                .mode = try guidText(ctx.a, mode),
            });
        }
        return out.items;
    }

    fn node(ctx: *Ctx, src_in: Src, scope: ?*const Scope, depth: u32, parent: ParentLayout) Error!?m.Node {
        const a = ctx.a;
        const t = src_in.base.getEnum("type") orelse return null;
        const g = guidOf(src_in.base.get("guid")) orelse return null;
        const kind = kindOf(src_in, t) orelse {
            try ctx.skip(t);
            return null;
        };
        var src = src_in;
        if (kind == .instance) if (src.swap orelse guidOf(src.get("overriddenSymbolID"))) |sw| {
            if (try ctx.view(sw)) |v| src.swapped = v;
        };
        // Variable modes this node sets hold for it and everything in it.
        const modes_before = ctx.modes.items.len;
        defer ctx.modes.shrinkRetainingCapacity(modes_before);
        if (src.get("variableModeBySetMap")) |vm| {
            const entries = vm.list("entries");
            for (0..entries.len()) |i| {
                const e = entries.at(i);
                const set = guidOf((e.get("variableSetID") orelse continue).get("guid")) orelse
                    (ctx.keyed((e.get("variableSetID") orelse continue).get("assetRef") orelse continue) orelse continue);
                const mode = guidOf(e.get("variableModeID")) orelse continue;
                try ctx.modes.append(ctx.keep, .{
                    .set = set,
                    .mode = mode,
                });
            }
        }
        const id = if (scope) |sc| try std.fmt.allocPrint(a, "{s};{d}:{d}", .{ sc.prefix, g >> 32, g & 0xffffffff }) else try guidText(a, g);
        var n: m.Node = .{
            .id = id,
            .kind = kind,
            .name = src.str("name") orelse "",
            .visible = src.visible orelse src.boolean("visible") orelse true,
            .locked = src.boolean("locked") orelse false,
            .opacity = src.float("opacity") orelse 1,
            .blend = blendOf(src.enumName("blendMode") orelse "PASS_THROUGH"),
        };
        var size_unknown = false;
        if (kind == .page) {
            if (src.get("backgroundColor")) |c| n.background = color(c);
        } else {
            // The file stores NaN where Figma has no value (docs/fig-format.md): an
            // unknown translation stays NaN until the parent places the node
            // (`placeUnknown`), an unknown size is fitted below (`fitUnknownGroup`).
            if (src.find(geom.Affine, "transform", finiteMatrix)) |tr| {
                n.transform = tr;
            } else if (src.get("transform")) |tr| {
                n.transform = matrix(tr);
                n.transform.e = std.math.nan(f32);
                n.transform.f = std.math.nan(f32);
            }
            if (src.find(Vec2, "size", finiteVec)) |s| {
                n.size = s;
            } else if (src.get("size") != null) size_unknown = true;
        }

        // A node that follows a style takes the style's values (its own copies may be
        // stale): fills and stroke paints from fill styles, effects, grids.
        n.fills = try ctx.paints(ctx.styled(src, "styleIdForFill", "fillPaints") orelse src.list("fillPaints"));
        n.strokes = try ctx.paints(ctx.styled(src, "styleIdForStrokeFill", "fillPaints") orelse src.list("strokePaints"));
        n.stroke = try ctx.strokeOf(src);
        n.effects = try ctx.effects(ctx.styled(src, "styleIdForEffect", "effects") orelse src.list("effects"));
        n.styles = .{
            .fill = try ctx.styleRef(src.get("styleIdForFill")),
            .stroke = try ctx.styleRef(src.get("styleIdForStrokeFill")),
            .effect = try ctx.styleRef(src.get("styleIdForEffect")),
            .text = try ctx.styleRef(src.get("styleIdForText")),
            .grid = try ctx.styleRef(src.get("styleIdForGrid")),
        };
        n.vars = try ctx.bindingsOf(src, .node);
        n.modes = try ctx.modesOf(src);

        const r = src.float("cornerRadius") orelse 0;
        n.radius = .{
            src.float("rectangleTopLeftCornerRadius") orelse r,
            src.float("rectangleTopRightCornerRadius") orelse r,
            src.float("rectangleBottomRightCornerRadius") orelse r,
            src.float("rectangleBottomLeftCornerRadius") orelse r,
        };
        // REST reports no corners for a section.
        if (std.mem.eql(u8, t, "SECTION")) n.radius = .{ 0, 0, 0, 0 };
        n.smoothing = src.float("cornerSmoothing") orelse 0;
        if (kind.isContainer()) n.clip = !(src.boolean("frameMaskDisabled") orelse false);

        if (src.enumName("stackMode")) |mode| if (!std.mem.eql(u8, mode, "NONE")) {
            n.layout = layoutOf(src, mode);
            if (n.layout.?.mode == .grid) {
                n.layout.?.columns = try ctx.tracks(src, "gridColumns", "gridColumnsSizing");
                n.layout.?.rows = try ctx.tracks(src, "gridRows", "gridRowsSizing");
            }
        };
        // Limits: a minimum of 0 and a maximum that is not a number are none.
        if (src.get("minSize")) |ms| if (ms.get("value")) |v| {
            if (v.getFloat("x")) |x| if (x > 0 and std.math.isFinite(x)) {
                n.min_width = x;
            };
            if (v.getFloat("y")) |y| if (y > 0 and std.math.isFinite(y)) {
                n.min_height = y;
            };
        };
        if (src.get("maxSize")) |ms| if (ms.get("value")) |v| {
            if (v.getFloat("x")) |x| if (std.math.isFinite(x)) {
                n.max_width = x;
            };
            if (v.getFloat("y")) |y| if (std.math.isFinite(y)) {
                n.max_height = y;
            };
        };
        if (parent.mode == .grid) n.cell = .{
            .column = trackIndex(parent.columns, guidOf(src.get("gridColumnAnchor"))),
            .row = trackIndex(parent.rows, guidOf(src.get("gridRowAnchor"))),
            .column_span = @max(1, src.uint("gridColumnSpan") orelse 1),
            .row_span = @max(1, src.uint("gridRowSpan") orelse 1),
            .h = cellAlign(src.enumName("gridChildHorizontalAlign") orelse "AUTO"),
            .v = cellAlign(src.enumName("gridChildVerticalAlign") orelse "AUTO"),
        };
        n.constraints = .{
            .h = hConstraint(src.enumName("horizontalConstraint") orelse "MIN"),
            .v = vConstraint(src.enumName("verticalConstraint") orelse "MIN"),
        };
        n.absolute = src.is("stackPositioning", "ABSOLUTE");
        n.sizing = sizingOf(src, kind, parent);
        n.grids = try ctx.grids(ctx.styled(src, "styleIdForGrid", "layoutGrids") orelse src.list("layoutGrids"), n.size);

        if (kind == .ellipse) if (src.get("arcData")) |ad| {
            n.arc = .{
                .start = ad.getFloat("startingAngle") orelse 0,
                .end = ad.getFloat("endingAngle") orelse std.math.tau,
                .inner = ad.getFloat("innerRadius") orelse 0,
            };
        };
        if (kind == .vector or kind == .text) if (src.get("vectorData")) |vd| {
            if (vd.getUint("vectorNetworkBlob")) |bi| if (bi < ctx.blobs.len) {
                var net = try blobs.network(a, ctx.blobs[bi]);
                figma.fitNetwork(&net, n.size);
                n.network = net;
            };
        };
        if (kind == .text) n.text = try ctx.text(src);
        switch (kind) {
            .vector, .star, .polygon, .boolean, .ellipse => n.geometry = try ctx.geometry(src),
            else => {},
        }
        if (kind == .star or kind == .polygon) n.count = src.uint("count") orelse 0;
        if (kind == .star) n.inner_scale = src.float("starInnerScale") orelse 0.382;
        if (kind == .boolean) {
            const op = src.enumName("booleanOperation") orelse "UNION";
            n.boolean_op = if (std.mem.eql(u8, op, "INTERSECT")) .intersect else if (std.mem.eql(u8, op, "SUBTRACT")) .subtract else if (std.mem.eql(u8, op, "XOR")) .exclude else .@"union";
        }
        if (src.boolean("mask") orelse false) {
            const mt = src.enumName("maskType") orelse "ALPHA";
            n.mask = if (std.mem.eql(u8, mt, "OUTLINE") or std.mem.eql(u8, mt, "VECTOR")) .vector else if (std.mem.eql(u8, mt, "LUMINANCE")) .luminance else .alpha;
        }
        n.reverse_z = src.boolean("stackReverseZIndex") orelse (if (kind == .instance) try ctx.mainBool(src, "stackReverseZIndex") else null) orelse false;
        const mods = src.list("transformModifiers");
        for (0..mods.len()) |i| {
            const mod = mods.at(i);
            if (!mod.fieldIs("type", "REPEAT")) continue;
            if (!(mod.getBool("visible") orelse true)) continue;
            const vertical = mod.fieldIs("axis", "Y");
            const off = mod.get("offset");
            n.repeat = .{
                .kind = if (mod.fieldIs("repeatType", "RADIAL")) .radial else .linear,
                .count = @max(1, mod.getUint("count") orelse 1),
                .offset = if (off) |o| (if (vertical) o.getFloat("y") else o.getFloat("x")) orelse 0 else 0,
                .vertical = vertical,
            };
        }

        try ctx.componentFields(&n, src, kind);

        var children: std.ArrayList(m.Node) = .empty;
        if (kind == .instance) {
            try ctx.expand(&n, src, g, scope, depth, try ctx.parentLayout(src, n.layout), &children);
        } else if (ctx.nodes.get(g)) |rec| {
            for (rec.children.items) |c| {
                const cv = (try ctx.view(c.guid)) orelse continue;
                const csrc = try ctx.childSrc(cv, c.guid, scope);
                if (try ctx.node(csrc, scope, depth, try ctx.parentLayout(src, n.layout))) |cn| try children.append(a, cn);
            }
        }
        n.children = children.items;
        if (size_unknown and n.kind != .group) n.size = .{};
        try ctx.placeUnknown(&n);
        if (size_unknown and n.kind == .group) fitUnknownGroup(&n);
        return n;
    }

    /// Sorts `defs` by `pos` (each def's `sortPosition`), keeping the read order of equal
    /// ones (an insertion sort: a component has a handful of properties).
    fn sortByPosition(defs: []m.PropDef, pos: [][]const u8) void {
        var i: usize = 1;
        while (i < defs.len) : (i += 1) {
            var j = i;
            while (j > 0 and std.mem.order(u8, pos[j], pos[j - 1]) == .lt) : (j -= 1) {
                std.mem.swap(m.PropDef, &defs[j], &defs[j - 1]);
                std.mem.swap([]const u8, &pos[j], &pos[j - 1]);
            }
        }
    }

    /// The component properties a component or component set offers, the properties a
    /// node's fields follow, and the values an instance gives them (Pubd draft 1). A
    /// variant property goes by its name.
    fn componentFields(ctx: *Ctx, n: *m.Node, src: Src, kind: m.Kind) Error!void {
        const a = ctx.a;
        if (kind == .component or kind == .component_set) {
            var defs: std.ArrayList(m.PropDef) = .empty;
            // Each property's `sortPosition`: the order the editor lists them in.
            var pos: std.ArrayList([]const u8) = .empty;
            const list = src.list("componentPropDefs");
            for (0..list.len()) |i| {
                const d = list.at(i);
                if (d.getBool("isDeleted") orelse false) continue;
                const pk = propKind(d.getEnum("type") orelse continue) orelse continue;
                const g = guidOf(d.get("id")) orelse continue;
                const name = d.getStr("name") orelse "";
                var options: std.ArrayList([]const u8) = .empty;
                if (pk == .variant) {
                    const orders = src.list("stateGroupPropertyValueOrders");
                    for (0..orders.len()) |k| {
                        const o = orders.at(k);
                        if (!std.mem.eql(u8, o.getStr("property") orelse "", name)) continue;
                        const vals = o.list("values");
                        for (0..vals.len()) |j| if (vals.at(j).str()) |sv| try options.append(a, sv);
                    }
                }
                try pos.append(a, d.getStr("sortPosition") orelse "");
                try defs.append(a, .{
                    .id = if (pk == .variant) name else try guidText(a, g),
                    .name = name,
                    .kind = pk,
                    .default = try propValueJson(a, pk, d.get("initialValue")),
                    .options = options.items,
                });
            }
            sortByPosition(defs.items, pos.items);
            n.properties = defs.items;
        }
        // The fields that follow a property.
        const pcm = src.get("parameterConsumptionMap");
        if (pcm) |p| {
            const entries = p.list("entries");
            for (0..entries.len()) |i| {
                const e = entries.at(i);
                const field = e.getEnum("variableField") orelse continue;
                const def = guidOf(e.path("variableData.value.propRefValue.defId")) orelse continue;
                try bindField(a, &n.bind, field, def);
            }
        }
        const refs = src.list("componentPropRefs");
        for (0..refs.len()) |i| {
            const r = refs.at(i);
            if (r.getBool("isDeleted") orelse false) continue;
            const field = r.getEnum("componentPropNodeField") orelse continue;
            const def = guidOf(r.get("defID")) orelse continue;
            try bindField(a, &n.bind, field, def);
        }
        if (kind == .instance) {
            var vals: std.ArrayList(m.PropValue) = .empty;
            const list = src.list("componentPropAssignments");
            for (0..list.len()) |i| {
                const p = list.at(i);
                const def = guidOf(p.get("defID")) orelse continue;
                const v = p.get("value") orelse continue;
                const json = if (v.getBool("boolValue")) |b|
                    (if (b) "true" else "false")
                else if (v.get("textValue")) |tv|
                    try jsonString(a, tv.getStr("characters") orelse "")
                else if (guidOf(v.get("guidValue"))) |gv|
                    try jsonString(a, try guidText(a, gv))
                else
                    continue;
                try vals.append(a, .{
                    .id = try guidText(a, def),
                    .value = json,
                });
                // A value that follows a variable.
                if (try ctx.bindingRef(p.get("varValue"))) |ref| {
                    const key = try std.fmt.allocPrint(a, "props/{s}", .{try guidText(a, def)});
                    const list2 = try a.alloc(m.VarBinding, n.vars.len + 1);
                    @memcpy(list2[0..n.vars.len], n.vars);
                    list2[n.vars.len] = .{
                        .key = key,
                        .variable = ref,
                    };
                    n.vars = list2;
                    ctx.bound += 1;
                }
            }
            n.props = vals.items;
        }
    }

    /// Children whose translation the file leaves unknown (NaN; seen on groups whose
    /// children are all hidden). In an auto layout the flow decides where a child goes:
    /// the layout engine arranges a copy of `n` and the child takes its place there.
    /// Elsewhere nothing in the file says where it is, and it sits at its parent's
    /// origin.
    fn placeUnknown(ctx: *Ctx, n: *m.Node) Error!void {
        var any = false;
        for (n.children) |*c| if (!placed(c)) {
            any = true;
        };
        if (!any) return;
        if (n.layout != null and n.kind.isContainer()) {
            var copy = n.*;
            copy.children = try cloneTree(ctx.a, n.children);
            _ = layout.arrange(ctx.a, &copy, .{}) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {},
            };
            for (n.children, copy.children) |*c, cc| {
                if (placed(c) or !layout.inFlow(n, c)) continue;
                if (!std.math.isFinite(cc.transform.e) or !std.math.isFinite(cc.transform.f)) continue;
                c.transform.e = cc.transform.e;
                c.transform.f = cc.transform.f;
            }
        }
        for (n.children) |*c| if (!placed(c)) {
            c.transform.e = 0;
            c.transform.f = 0;
        };
    }

    /// Field `name` of an instance's main component, for a field the instance's own record
    /// leaves to its main (`stackReverseZIndex`: the main's stacking order shows).
    fn mainBool(ctx: *Ctx, src: Src, name: []const u8) Error!?bool {
        const sd = src.get("symbolData");
        const sym = src.swap orelse guidOf(src.get("overriddenSymbolID")) orelse guidOf(if (sd) |d| d.get("symbolID") else null) orelse return null;
        const v = (try ctx.view(sym)) orelse return null;
        return v.getBool(name);
    }

    /// An instance's children: its component's, with this instance's overrides, derived
    /// layout and property values applied, ids `I<instance path>;<node>` as REST gives.
    fn expand(ctx: *Ctx, n: *m.Node, src: Src, g: u64, outer: ?*const Scope, depth: u32, pl: ParentLayout, out: *std.ArrayList(m.Node)) Error!void {
        const a = ctx.a;
        const sd = src.get("symbolData");
        // Scaled as a whole (Figma's scale tool), as REST's `uniformScaleFactor`.
        if (sd) |d| if (d.getFloat("uniformScaleFactor")) |f| if (std.math.isFinite(f) and f > 0 and f != 1) {
            n.scale = f;
        };
        const sym = src.swap orelse guidOf(src.get("overriddenSymbolID")) orelse guidOf(if (sd) |d| d.get("symbolID") else null) orelse return;
        if (ctx.nodes.contains(sym)) n.component = try guidText(a, sym);
        if (depth >= max_instance_depth) return;
        const rec = ctx.nodes.get(sym) orelse return;

        var ovs: std.ArrayList(Ov) = .empty;
        if (sd) |d| try ctx.addOvs(&ovs, d.list("symbolOverrides"));
        try ctx.addOvs(&ovs, src.list("derivedSymbolData"));
        const key = overrideKey(src.base);
        if (outer) |o| for (o.ovs) |ov| {
            if (ov.path.len > 1 and (ov.path[0] == g or ov.path[0] == key)) try ovs.append(a, .{
                .path = ov.path[1..],
                .rec = ov.rec,
            });
        };
        const scope: Scope = .{
            .prefix = if (std.mem.startsWith(u8, n.id, "I")) n.id else try std.fmt.allocPrint(a, "I{s}", .{n.id}),
            .ovs = ovs.items,
            .props = src.list("componentPropAssignments"),
        };
        for (rec.children.items) |c| {
            const cv = (try ctx.view(c.guid)) orelse continue;
            const csrc = try ctx.childSrc(cv, c.guid, &scope);
            if (try ctx.node(csrc, &scope, depth + 1, pl)) |cn| try out.append(a, cn);
        }
    }

    fn addOvs(ctx: *Ctx, ovs: *std.ArrayList(Ov), list: kiwi.Items) !void {
        for (0..list.len()) |i| {
            const rec = list.at(i);
            const guids = (rec.get("guidPath") orelse continue).list("guids");
            if (guids.len() == 0) continue;
            const path = try ctx.a.alloc(u64, guids.len());
            for (path, 0..) |*p, k| p.* = guidOf(guids.at(k)) orelse 0;
            try ovs.append(ctx.a, .{
                .path = path,
                .rec = rec,
            });
        }
    }

    /// The style node a `styleIdFor…` field names, when it is in the file.
    fn styleNode(ctx: *Ctx, src: Src, ref_field: []const u8) ?View {
        const g = ctx.styleGuid(src.get(ref_field)) orelse return null;
        return ctx.view(g) catch null;
    }

    /// The style a `styleIdFor…` value names: by guid, or by a library's key.
    fn styleGuid(ctx: *Ctx, v: ?View) ?u64 {
        const ref = v orelse return null;
        if (guidOf(ref.get("guid"))) |g| return g;
        const key = (ref.get("assetRef") orelse return null).getStr("key") orelse return null;
        return ctx.style_keys.get(key);
    }

    /// Field `name` of the style the node follows through `ref_field`.
    fn styled(ctx: *Ctx, src: Src, ref_field: []const u8, name: []const u8) ?kiwi.Items {
        const st = ctx.styleNode(src, ref_field) orelse return null;
        if (st.get(name) == null) return null;
        return st.list(name);
    }

    fn styleRef(ctx: *Ctx, v: ?View) !?[]const u8 {
        const g = ctx.styleGuid(v) orelse return null;
        return try guidText(ctx.a, g);
    }

    fn paints(ctx: *Ctx, list: kiwi.Items) ![]m.Paint {
        var out: std.ArrayList(m.Paint) = .empty;
        for (0..list.len()) |i| if (try ctx.paint(list.at(i))) |p| try out.append(ctx.a, p);
        return out.items;
    }

    /// The colour a colour variable binding (`colorVar`) gives: the variable's value in
    /// its collection's default mode, through aliases. A paint keeps its last colour
    /// beside the binding, but that copy can be stale (a library variable changed since):
    /// the variable wins, as in Figma. Null when the binding is not resolved here.
    fn boundColor(ctx: *Ctx, binding: ?View) Error!?m.Color {
        var b = binding orelse return null;
        var hops: u32 = 0;
        while (hops < 16) : (hops += 1) {
            const val = b.get("value") orelse return null;
            if (val.get("colorValue")) |c| return color(c);
            const alias = val.get("alias") orelse return null;
            const vg = guidOf(alias.get("guid")) orelse ctx.keyedVersion(alias.get("assetRef") orelse return null) orelse return null;
            const variable = (try ctx.view(vg)) orelse return null;
            const entries = (variable.get("variableDataValues") orelse return null).list("entries");
            if (entries.len() == 0) return null;
            const mode = try ctx.defaultMode(variable);
            var pick = entries.at(0);
            if (mode) |md| for (0..entries.len()) |i| {
                if (guidOf(entries.at(i).get("modeID")) == md) {
                    pick = entries.at(i);
                    break;
                }
            };
            b = pick.get("variableData") orelse return null;
        }
        return null;
    }

    /// The mode variable `v` takes here: its collection's mode set on the node or an
    /// ancestor (the innermost), else the collection's first by `sortPosition`.
    fn defaultMode(ctx: *Ctx, v: View) Error!?u64 {
        const ref = v.get("variableSetID") orelse return null;
        const sg = guidOf(ref.get("guid")) orelse ctx.keyed(ref.get("assetRef") orelse return null) orelse return null;
        var at = ctx.modes.items.len;
        while (at > 0) {
            at -= 1;
            if (ctx.modes.items[at].set == sg) return ctx.modes.items[at].mode;
        }
        const set = (try ctx.view(sg)) orelse return null;
        const modes = set.list("variableSetModes");
        var best: ?u64 = null;
        var best_pos: []const u8 = "";
        for (0..modes.len()) |i| {
            const md = modes.at(i);
            const pos = md.getStr("sortPosition") orelse "";
            if (best == null or std.mem.lessThan(u8, pos, best_pos)) {
                best = guidOf(md.get("id"));
                best_pos = pos;
            }
        }
        return best;
    }

    fn paint(ctx: *Ctx, v: View) !?m.Paint {
        const t = v.getEnum("type") orelse return null;
        var p: m.Paint = .{
            .kind = .solid,
            .visible = v.getBool("visible") orelse true,
            .opacity = v.getFloat("opacity") orelse 1,
            .blend = blendOf(v.getEnum("blendMode") orelse "NORMAL"),
        };
        if (std.mem.eql(u8, t, "SOLID")) {
            p.color = (try ctx.boundColor(v.get("colorVar"))) orelse if (v.get("color")) |c| color(c) else .{};
            p.variable = try ctx.bindingRef(v.get("colorVar"));
        } else if (std.mem.startsWith(u8, t, "GRADIENT_")) {
            const gk = t["GRADIENT_".len..];
            p.kind = if (std.mem.eql(u8, gk, "LINEAR")) .linear else if (std.mem.eql(u8, gk, "RADIAL")) .radial else if (std.mem.eql(u8, gk, "ANGULAR")) .angular else .diamond;
            // The paint's transform maps the node's unit square into gradient space,
            // where a linear gradient runs (0, .5) to (1, .5) and the others sit at
            // (.5, .5) reaching (1, .5) and (.5, 1). The handles are those points
            // mapped back.
            const tr = if (v.get("transform")) |x| matrix(x) else geom.Affine.identity;
            const inv = tr.invert() orelse geom.Affine.identity;
            const canon: [3]Vec2 = if (p.kind == .linear) .{
                .{
                    .y = 0.5,
                },
                .{
                    .x = 1,
                    .y = 0.5,
                },
                .{
                    .y = 1,
                },
            } else .{
                .{
                    .x = 0.5,
                    .y = 0.5,
                },
                .{
                    .x = 1,
                    .y = 0.5,
                },
                .{
                    .x = 0.5,
                    .y = 1,
                },
            };
            for (&p.handles, canon) |*h, c| h.* = inv.apply(c);
            const stops = v.list("stops");
            // Stops bound to colour variables are listed again, with their bindings, in
            // `stopsVar`.
            const svars = v.list("stopsVar");
            const out = try ctx.a.alloc(m.Stop, stops.len());
            for (out, 0..) |*s, i| {
                const sv: ?View = if (i < svars.len()) svars.at(i) else null;
                const cv = if (sv) |x| x.get("colorVar") else null;
                s.* = .{
                    .at = stops.at(i).getFloat("position") orelse 0,
                    .color = (try ctx.boundColor(cv)) orelse if (stops.at(i).get("color")) |c| color(c) else .{},
                    .variable = try ctx.bindingRef(cv),
                };
                if (s.variable != null) ctx.bound += 1;
            }
            p.stops = out;
        } else if (std.mem.eql(u8, t, "IMAGE")) {
            p.kind = .image;
            const hash = (v.path("image.hash") orelse return null).bytes() orelse return null;
            if (hash.len == 0 or hash.len > 64) return null;
            const ref = try ctx.a.alloc(u8, hash.len * 2);
            for (hash, 0..) |b, i| _ = std.fmt.bufPrint(ref[i * 2 ..][0..2], "{x:0>2}", .{b}) catch unreachable;
            p.asset = ref;
            var seen = false;
            for (ctx.images.items) |im| if (std.mem.eql(u8, im.ref, ref)) {
                seen = true;
            };
            if (!seen) {
                const kept = try ctx.keep.dupe(u8, ref);
                try ctx.images.append(ctx.keep, .{
                    .ref = kept,
                    .hash = kept,
                });
            }
            const sm = v.getEnum("imageScaleMode") orelse "FILL";
            p.scale = if (std.mem.eql(u8, sm, "FIT")) .fit else if (std.mem.eql(u8, sm, "TILE")) .tile else if (std.mem.eql(u8, sm, "STRETCH")) .stretch else if (std.mem.eql(u8, sm, "CROP")) .crop else .fill;
            if (p.scale == .crop or p.scale == .stretch) if (v.get("transform")) |x| {
                p.image_transform = matrix(x);
            };
            if (p.scale == .tile) p.tile = v.getFloat("scale") orelse 1;
        } else if (std.mem.eql(u8, t, "PATTERN")) {
            p.kind = .pattern;
            p.source = try guidText(ctx.a, guidOf(v.get("sourceNodeId")) orelse return null);
            const tt = v.getEnum("patternTileType") orelse "RECTANGULAR";
            p.tile_type = if (std.mem.eql(u8, tt, "HORIZONTAL_HEXAGONAL")) .horizontal_hexagonal else if (std.mem.eql(u8, tt, "VERTICAL_HEXAGONAL")) .vertical_hexagonal else .rectangular;
            p.tile = v.getFloat("scale") orelse 1;
            if (v.get("patternSpacing")) |sp| p.spacing = vec(sp);
            p.h_align = tileAlign(v.getEnum("horizontalAlignment") orelse "START");
            p.v_align = tileAlign(v.getEnum("verticalAlignment") orelse "START");
        } else return null;
        if (p.variable != null) ctx.bound += 1;
        var pv: std.ArrayList(m.VarBinding) = .empty;
        try ctx.bindTo(&pv, "opacity", v.get("opacityVar"));
        p.vars = pv.items;
        return p;
    }

    /// The fill outline (`fillGeometry`), with per-region fills from the vector's style
    /// overrides (`vectorData.styleOverrideTable`, by the path's `styleID`).
    fn geometry(ctx: *Ctx, src: Src) ![]m.GeometryPath {
        const geo = src.list("fillGeometry");
        var out: std.ArrayList(m.GeometryPath) = .empty;
        const table = if (src.get("vectorData")) |vd| vd.list("styleOverrideTable") else kiwi.Items{
            .s = ctx.s,
            .items = &.{},
        };
        for (0..geo.len()) |i| {
            const pth = geo.at(i);
            const d = try ctx.pathData(pth) orelse continue;
            var gp: m.GeometryPath = .{
                .d = d,
                .winding = if (pth.fieldIs("windingRule", "ODD")) .evenodd else .nonzero,
            };
            const sid = pth.getUint("styleID") orelse 0;
            if (sid != 0) for (0..table.len()) |k| {
                const o = table.at(k);
                if ((o.getUint("styleID") orelse 0) != sid) continue;
                if (o.get("fillPaints") != null) gp.fills = try ctx.paints(o.list("fillPaints"));
                break;
            };
            try out.append(ctx.a, gp);
        }
        return out.items;
    }

    /// A path's commands blob as SVG path data; null when empty or missing.
    fn pathData(ctx: *Ctx, pth: View) !?[]const u8 {
        const bi = pth.getUint("commandsBlob") orelse return null;
        if (bi >= ctx.blobs.len) return null;
        const d = try blobs.commandsToSvg(ctx.a, ctx.blobs[bi]);
        return if (d.len == 0) null else d;
    }

    fn strokeOf(ctx: *Ctx, src: Src) !m.Stroke {
        var s: m.Stroke = .{
            .weight = src.float("strokeWeight") orelse 1,
        };
        const geo = src.list("strokeGeometry");
        if (geo.len() > 0) {
            var list: std.ArrayList(m.OutlinePath) = .empty;
            for (0..geo.len()) |i| {
                const pth = geo.at(i);
                const d = try ctx.pathData(pth) orelse continue;
                try list.append(ctx.a, .{
                    .d = d,
                    .winding = if (pth.fieldIs("windingRule", "ODD")) .evenodd else .nonzero,
                });
            }
            s.outline = list.items;
        }
        if (src.enumName("strokeAlign")) |al| s.@"align" = if (std.mem.eql(u8, al, "INSIDE")) .inside else if (std.mem.eql(u8, al, "OUTSIDE")) .outside else .center;
        if (src.enumName("strokeCap")) |c| s.cap = if (std.mem.eql(u8, c, "ROUND")) .round else if (std.mem.eql(u8, c, "SQUARE")) .square else .none;
        if (src.enumName("strokeJoin")) |j| s.join = if (std.mem.eql(u8, j, "ROUND")) .round else if (std.mem.eql(u8, j, "BEVEL")) .bevel else .miter;
        if (src.float("miterLimit")) |ml| if (ml >= 1) {
            s.miter = ml;
        };
        const dashes = src.list("dashPattern");
        if (dashes.len() > 0) {
            const d = try ctx.a.alloc(f32, dashes.len());
            for (d, 0..) |*o, i| o.* = dashes.at(i).float() orelse 0;
            s.dashes = d;
        }
        const wps = src.list("variableWidthPoints");
        if (wps.len() > 0) {
            const out = try ctx.a.alloc(m.WidthPoint, wps.len());
            for (out, 0..) |*o, i| {
                const w = wps.at(i);
                o.* = .{
                    .segment = @intCast(@max(0, w.getInt("segmentId") orelse 0)),
                    .at = w.getFloat("position") orelse 0,
                    .ascent = w.getFloat("ascent") orelse 0,
                    .descent = w.getFloat("descent") orelse 0,
                };
            }
            s.widths = out;
        }
        s.brush = try ctx.brushOf(src);
        if (src.get("dynamicStrokeSettings")) |d| s.dynamic = .{
            .frequency = d.getFloat("frequency") orelse 0,
            .wiggle = d.getFloat("wiggle") orelse 0,
            .smoothen = d.getFloat("smoothen") orelse 0,
        };
        if (src.boolean("borderStrokeWeightsIndependent") orelse false) {
            const sides: [4]f32 = .{
                src.float("borderTopWeight") orelse 0,
                src.float("borderRightWeight") orelse 0,
                src.float("borderBottomWeight") orelse 0,
                src.float("borderLeftWeight") orelse 0,
            };
            // Four equal sides are one weight (as REST reports them).
            if (sides[0] == sides[1] and sides[1] == sides[2] and sides[2] == sides[3]) {
                s.weight = sides[0];
            } else s.sides = sides;
        }
        return s;
    }

    /// The brush a stroke uses (`strokeBrushGuid`, a `BRUSH` node on the internal page):
    /// its shape and settings, with the node's own settings and resolved stamps.
    fn brushOf(ctx: *Ctx, src: Src) !?m.Brush {
        const g = guidOf(src.get("strokeBrushGuid")) orelse return null;
        const bv = (try ctx.view(g)) orelse return null;
        var b: m.Brush = .{
            .name = bv.getStr("name") orelse "",
            .kind = if (bv.fieldIs("brushType", "SCATTER")) .scatter else .stretch,
            .size = if (bv.get("size")) |sz| vec(sz) else .{},
            .reverse = if (src.get("stretchStrokeSettings")) |ss| ss.fieldIs("orientation", "REVERSE") else false,
            .scatter = if (bv.get("scatterStrokeSettings")) |sc| scatterOf(sc) else null,
            .adjust = if (src.get("scatterStrokeSettings")) |sc| scatterOf(sc) else null,
        };
        const geo = bv.list("fillGeometry");
        var paths: std.ArrayList(m.GeometryPath) = .empty;
        for (0..geo.len()) |i| {
            const pth = geo.at(i);
            const d = try ctx.pathData(pth) orelse continue;
            try paths.append(ctx.a, .{
                .d = d,
                .winding = if (pth.fieldIs("windingRule", "ODD")) .evenodd else .nonzero,
            });
        }
        b.geometry = paths.items;
        const stamps = src.list("scatterBrushTransforms");
        if (stamps.len() > 0) {
            const out = try ctx.a.alloc(geom.Affine, stamps.len());
            for (out, 0..) |*o, i| o.* = matrix(stamps.at(i));
            b.stamps = out;
        }
        return b;
    }

    /// The fields of an effect that follow variables (`radiusVar`, `colorVar`, ...).
    fn effectBindings(ctx: *Ctx, e: View) ![]m.VarBinding {
        var out: std.ArrayList(m.VarBinding) = .empty;
        const map = [_][2][]const u8{
            .{ "colorVar", "color" },
            .{ "radiusVar", "radius" },
            .{ "spreadVar", "spread" },
            .{ "xVar", "offset/0" },
            .{ "yVar", "offset/1" },
            .{ "noiseSizeXVar", "grain/0" },
            .{ "noiseSizeYVar", "grain/1" },
            .{ "secondaryColorVar", "secondary" },
        };
        for (map) |x| try ctx.bindTo(&out, x[1], e.get(x[0]));
        return out.items;
    }

    fn effects(ctx: *Ctx, list: kiwi.Items) ![]m.Effect {
        var out: std.ArrayList(m.Effect) = .empty;
        for (0..list.len()) |i| {
            const e = list.at(i);
            const t = e.getEnum("type") orelse continue;
            const kind: m.EffectKind = if (std.mem.eql(u8, t, "DROP_SHADOW")) .drop_shadow else if (std.mem.eql(u8, t, "INNER_SHADOW")) .inner_shadow else if (std.mem.eql(u8, t, "FOREGROUND_BLUR")) .layer_blur else if (std.mem.eql(u8, t, "BACKGROUND_BLUR")) .background_blur else if (std.mem.eql(u8, t, "NOISE")) .noise else if (std.mem.eql(u8, t, "GRAIN")) .texture else continue;
            const shadow = kind == .drop_shadow or kind == .inner_shadow;
            const blur = kind == .layer_blur or kind == .background_blur;
            const nt = e.getEnum("noiseType") orelse "MONOTONE";
            // REST reports what each kind uses; the file stores every field. Keep what
            // the kind uses, REST's defaults elsewhere.
            try out.append(ctx.a, .{
                .kind = kind,
                .visible = e.getBool("visible") orelse true,
                .color = if (shadow or kind == .noise) (if (e.get("color")) |c| color(c) else .{}) else .{
                    .a = 0.25,
                },
                .offset = if (shadow) (if (e.get("offset")) |o| vec(o) else .{}) else .{},
                .radius = if (kind == .noise) 0 else e.getFloat("radius") orelse 0,
                .spread = if (shadow) e.getFloat("spread") orelse 0 else 0,
                .behind = kind == .drop_shadow and (e.getBool("showShadowBehindNode") orelse false),
                .blend = if (shadow or kind == .noise) blendOf(e.getEnum("blendMode") orelse "NORMAL") else .normal,
                .progressive = if (blur and e.fieldIs("blurOpType", "PROGRESSIVE")) .{
                    .start = if (e.get("startOffset")) |o| vec(o) else .{},
                    .end = if (e.get("endOffset")) |o| vec(o) else .{
                        .y = 1,
                    },
                    .start_radius = e.getFloat("startRadius") orelse 0,
                } else null,
                // The file keeps the grain's width and height apart (REST gives one).
                .grain = if (e.get("noiseSize")) |ns| vec(ns) else .{
                    .x = 2,
                    .y = 2,
                },
                .noise = if (std.mem.eql(u8, nt, "DUOTONE")) .duotone else if (std.mem.eql(u8, nt, "MULTITONE")) .multitone else .monotone,
                .density = e.getFloat("density") orelse 0.5,
                .secondary = if (e.get("secondaryColor")) |c| color(c) else .{},
                .opacity = if (kind == .noise and std.mem.eql(u8, nt, "MULTITONE")) e.getFloat("opacity") orelse 1 else 1,
                .clip = e.getBool("clipToShape") orelse true,
                .seed = if (kind == .noise or kind == .texture) e.getUint("seed") orelse 0 else 0,
                .vars = try ctx.effectBindings(e),
            });
        }
        return out.items;
    }

    /// Layout grids. A square grid has only a size (REST gives no count, gutter or
    /// alignment for it); a stretched grid's section size is what its count, gutter and
    /// offset leave of the frame (REST reports it resolved).
    fn grids(ctx: *Ctx, list: kiwi.Items, size: Vec2) ![]m.Grid {
        var out: std.ArrayList(m.Grid) = .empty;
        for (0..list.len()) |i| {
            const g = list.at(i);
            const pat = g.getEnum("pattern") orelse "STRIPES";
            const al = g.getEnum("type") orelse "STRETCH";
            const square = std.mem.eql(u8, pat, "GRID");
            const rows = g.fieldIs("axis", "Y");
            const count: u32 = if (square) 0 else @intCast(@max(0, g.getInt("numSections") orelse 0));
            const gutter = if (square) 0 else g.getFloat("gutterSize") orelse 0;
            const offset = g.getFloat("offset") orelse 0;
            const alignment: m.GridAlign = if (square or std.mem.eql(u8, al, "MIN")) .start else if (std.mem.eql(u8, al, "MAX")) .end else if (std.mem.eql(u8, al, "CENTER")) .center else .stretch;
            var section = g.getFloat("sectionSize") orelse 0;
            if (alignment == .stretch and count > 0) {
                const total = if (rows) size.y else size.x;
                const c: f32 = @floatFromInt(count);
                section = (total - 2 * offset - gutter * (c - 1)) / c;
            }
            try out.append(ctx.a, .{
                .kind = if (square) .grid else if (rows) .rows else .columns,
                .count = count,
                .gutter = gutter,
                .offset = offset,
                .size = section,
                .@"align" = alignment,
                .color = if (g.get("color")) |c| color(c) else .{
                    .r = 1,
                    .a = 0.1,
                },
                .visible = g.getBool("visible") orelse true,
                .vars = try ctx.gridBindings(g),
            });
        }
        return out.items;
    }

    /// The fields of a layout grid that follow variables.
    fn gridBindings(ctx: *Ctx, g: View) ![]m.VarBinding {
        var out: std.ArrayList(m.VarBinding) = .empty;
        const map = [_][2][]const u8{
            .{ "numSectionsVar", "count" },
            .{ "gutterSizeVar", "gutter" },
            .{ "offsetVar", "offset" },
            .{ "sectionSizeVar", "size" },
        };
        for (map) |x| try ctx.bindTo(&out, x[1], g.get(x[0]));
        return out.items;
    }

    fn text(ctx: *Ctx, src: Src) !m.Text {
        const td = src.text orelse src.get("textData");
        var t: m.Text = .{
            .text = if (td) |d| d.getStr("characters") orelse "" else "",
        };
        // A text style's font, size and spacing win over the node's own copies.
        var styled_src = src;
        if (ctx.styleNode(src, "styleIdForText")) |st| {
            const layers = try ctx.a.alloc(View, src.layers.len + 1);
            @memcpy(layers[0..src.layers.len], src.layers);
            layers[src.layers.len] = st;
            styled_src.layers = layers;
        }
        t.style = textStyle(styled_src);
        t.style.vars = try ctx.bindingsOf(styled_src, .text);
        t.resize = if (src.base.fieldIs("type", "TEXT_PATH")) .fixed else textResize(src.enumName("textAutoResize") orelse "NONE");
        // REST reports a fixed box that truncates as `TRUNCATE`.
        if (t.resize == .fixed and src.is("textTruncation", "ENDING")) t.resize = .truncate;
        const ha = src.enumName("textAlignHorizontal") orelse "LEFT";
        t.@"align" = if (std.mem.eql(u8, ha, "CENTER")) .center else if (std.mem.eql(u8, ha, "RIGHT")) .right else if (std.mem.eql(u8, ha, "JUSTIFIED")) .justify else .left;
        const va = src.enumName("textAlignVertical") orelse "TOP";
        t.valign = if (std.mem.eql(u8, va, "CENTER")) .center else if (std.mem.eql(u8, va, "BOTTOM")) .bottom else .top;
        if (src.is("textTruncation", "ENDING")) t.truncation = .ending;
        if (src.get("maxLines")) |ml| if (ml.int()) |k| if (k >= 1) {
            t.max_lines = @intCast(k);
        };
        const wrap = src.enumName("textWrapStyle") orelse "AUTO";
        t.wrap = if (std.mem.eql(u8, wrap, "BALANCE")) .balance else if (std.mem.eql(u8, wrap, "PRETTY")) .pretty else .auto;
        if (src.is("leadingTrim", "CAP_HEIGHT")) t.leading_trim = .cap_height;
        t.hanging_punctuation = src.boolean("hangingPunctuation") orelse false;
        t.hanging_list = src.boolean("hangingList") orelse false;
        // Kiwi leaves out a false bool: an absent `textDecorationSkipInk` is off (Figma
        // draws such underlines through descenders).
        t.skip_ink = src.boolean("textDecorationSkipInk") orelse false;

        if (td) |d| {
            const lines = d.list("lines");
            var any_list = false;
            for (0..lines.len()) |k| {
                const l = lines.at(k);
                if (!l.fieldIs("lineType", "PLAIN") or (l.getInt("indentationLevel") orelse 0) != 0) any_list = true;
            }
            if (any_list) {
                const lists = try ctx.a.alloc(m.ParagraphList, lines.len());
                for (lists, 0..) |*pl, k| {
                    const l = lines.at(k);
                    const lt = l.getEnum("lineType") orelse "PLAIN";
                    pl.* = .{
                        .type = if (std.mem.eql(u8, lt, "ORDERED_LIST")) .ordered else if (std.mem.eql(u8, lt, "UNORDERED_LIST")) .unordered else .none,
                        .indent = @intCast(std.math.clamp(l.getInt("indentationLevel") orelse 0, 0, 255)),
                    };
                }
                t.lists = lists;
            }
        }
        if (src.get("textPathStart")) |ps| {
            // `tValue` counts segments: the whole part picks one, the rest is the
            // position along it (only 0 seen so far).
            const tv = @max(0, ps.getFloat("tValue") orelse 0);
            t.path_start = .{
                .segment = @intFromFloat(@floor(tv)),
                .position = tv - @floor(tv),
            };
        }

        // Runs: consecutive characters with the same style id, each id an entry of the
        // override table (a partial node: font, fills, decoration, …).
        const d = td orelse return t;
        const ids = d.list("characterStyleIDs");
        const table = d.list("styleOverrideTable");
        var runs: std.ArrayList(m.Run) = .empty;
        var i: usize = 0;
        while (i < ids.len()) {
            const id = ids.at(i).uint() orelse 0;
            var j = i + 1;
            while (j < ids.len() and (ids.at(j).uint() orelse 0) == id) j += 1;
            if (id != 0) for (0..table.len()) |k| {
                const o = table.at(k);
                if ((o.getUint("styleID") orelse 0) != id) continue;
                const osrc: Src = .{
                    .base = o,
                };
                var run: m.Run = .{
                    .from = @intCast(i),
                    .to = @intCast(j),
                    .style = runStyle(osrc, styled_src),
                };
                run.style.vars = try ctx.bindingsOf(osrc, .text);
                if (o.get("fillPaints") != null) run.fills = try ctx.paints(o.list("fillPaints"));
                try runs.append(ctx.a, run);
                break;
            };
            i = j;
        }
        t.runs = runs.items;
        try ctx.laidOut(src, &t, d);
        return t;
    }

    /// Figma's own layout of the text (`derivedTextData`): the glyphs (an outline per
    /// commands blob, in ems, y up, at a position and size) and the decorations, kept so
    /// the text draws as Figma drew it when its font is missing. Left out when a text
    /// property replaced the characters and no layout came with the new ones.
    fn laidOut(ctx: *Ctx, src: Src, t: *m.Text, td: View) !void {
        const dtd = src.get("derivedTextData") orelse return;
        if (src.text != null) {
            var fresh = false;
            for (src.layers) |l| if (l.get("derivedTextData") != null) {
                fresh = true;
            };
            if (!fresh) return;
        }
        // The style id of each character, to tie a glyph or decoration to a run.
        const ids = td.list("characterStyleIDs");
        const gl = dtd.list("glyphs");
        var glyphs: std.ArrayList(m.TextGlyph) = .empty;
        for (0..gl.len()) |i| {
            const g = gl.at(i);
            const bi = g.getUint("commandsBlob") orelse continue;
            if (bi >= ctx.blobs.len or ctx.blobs[bi].len == 0) continue;
            const got = try ctx.glyph_ids.getOrPut(ctx.keep, bi);
            if (!got.found_existing) {
                got.value_ptr.* = @intCast(ctx.glyph_paths.items.len);
                try ctx.glyph_paths.append(ctx.keep, try blobs.commandsToSvg(ctx.keep, ctx.blobs[bi]));
            }
            const pos = g.get("position");
            try glyphs.append(ctx.a, .{
                .outline = got.value_ptr.*,
                .x = if (pos) |p| p.getFloat("x") orelse 0 else 0,
                .y = if (pos) |p| p.getFloat("y") orelse 0 else 0,
                .size = g.getFloat("fontSize") orelse 0,
                .char = g.getUint("firstCharacter") orelse 0,
                .rotation = g.getFloat("rotation") orelse 0,
            });
        }
        var rects: std.ArrayList(m.TextRect) = .empty;
        const decos = dtd.list("decorations");
        for (0..decos.len()) |i| {
            const dc = decos.at(i);
            const sid = dc.getUint("styleID") orelse 0;
            var char: u32 = 0;
            for (0..ids.len()) |k| if ((ids.at(k).uint() orelse 0) == sid) {
                char = @intCast(k);
                break;
            };
            const rl = dc.list("rects");
            for (0..rl.len()) |k| {
                const r = rl.at(k);
                try rects.append(ctx.a, .{
                    .rect = .{ r.getFloat("x") orelse 0, r.getFloat("y") orelse 0, r.getFloat("w") orelse 0, r.getFloat("h") orelse 0 },
                    .char = char,
                });
            }
        }
        t.glyphs = glyphs.items;
        t.glyph_rects = rects.items;
    }
};

/// True when the node's translation is known (see `Ctx.placeUnknown`).
fn placed(n: *const m.Node) bool {
    return std.math.isFinite(n.transform.e) and std.math.isFinite(n.transform.f);
}

/// A copy of the nodes and their subtrees, so a layout pass over it leaves the originals
/// alone (the other fields are shared, read only).
fn cloneTree(a: std.mem.Allocator, nodes: []const m.Node) error{OutOfMemory}![]m.Node {
    const out = try a.dupe(m.Node, nodes);
    for (out) |*c| c.children = try cloneTree(a, c.children);
    return out;
}

/// A group whose size the file leaves unknown (NaN): Figma stores that when its children
/// are all hidden. A group fits its children (the layout engine's rule,
/// `layout.storedGroupBox`); with nothing visible it has no box, size 0, as the file's
/// own hugging auto layouts around such groups measure it. (Any other node whose size is
/// unknown gets 0; none seen.)
fn fitUnknownGroup(n: *m.Node) void {
    n.size = .{};
    if (n.repeat != null) return;
    const b = layout.storedGroupBox(n) orelse return;
    for (n.children) |*c| {
        c.transform.e -= b.min.x;
        c.transform.f -= b.min.y;
    }
    const t = n.transform;
    n.transform.e += t.a * b.min.x + t.c * b.min.y;
    n.transform.f += t.b * b.min.x + t.d * b.min.y;
    n.size = b.size;
}

/// The auto layout a child sits in (for a grid, its track ids, which cells name).
const ParentLayout = struct {
    mode: enum {
        none,
        horizontal,
        vertical,
        grid,
    } = .none,
    columns: []const u64 = &.{},
    rows: []const u64 = &.{},
};

fn trackIndex(ids: []const u64, id: ?u64) u32 {
    const g = id orelse return 0;
    for (ids, 0..) |t, i| if (t == g) return @intCast(i);
    return 0;
}

fn cellAlign(s: []const u8) m.CellAlign {
    if (std.mem.eql(u8, s, "MIN")) return .start;
    if (std.mem.eql(u8, s, "CENTER")) return .center;
    if (std.mem.eql(u8, s, "MAX")) return .end;
    return .auto;
}

/// How a node sizes in auto layout, given when it sits in auto layout or has its own
/// (REST's `layoutSizingHorizontal`/`Vertical`): it fills along its parent's axis when it
/// grows, across it when it stretches; it hugs where its own layout or text hugs; an
/// absolute child is fixed.
fn sizingOf(src: Src, kind: m.Kind, parent: ParentLayout) ?m.Sizing {
    const own = src.enumName("stackMode");
    const has_own = if (own) |o| !std.mem.eql(u8, o, "NONE") else false;
    if (parent.mode == .none and !has_own) return null;
    var s: m.Sizing = .{};
    if (parent.mode != .none and src.is("stackPositioning", "ABSOLUTE")) return s;
    if (has_own) {
        const l = layoutOf(src, own.?);
        if (l.width == .hug) s.w = .hug;
        if (l.height == .hug) s.h = .hug;
    }
    if (kind == .text) {
        const r = src.enumName("textAutoResize") orelse "NONE";
        if (std.mem.eql(u8, r, "WIDTH_AND_HEIGHT")) {
            s.w = .hug;
            s.h = .hug;
        } else if (std.mem.eql(u8, r, "HEIGHT")) s.h = .hug;
    }
    const grow = (src.float("stackChildPrimaryGrow") orelse 0) > 0;
    const stretch = src.is("stackChildAlignSelf", "STRETCH");
    switch (parent.mode) {
        .none => {},
        .horizontal, .grid => {
            if (grow) s.w = .fill;
            if (stretch) s.h = .fill;
        },
        .vertical => {
            if (grow) s.h = .fill;
            if (stretch) s.w = .fill;
        },
    }
    return s;
}

fn propKind(t: []const u8) ?m.PropKind {
    if (std.mem.eql(u8, t, "BOOL")) return .boolean;
    if (std.mem.eql(u8, t, "TEXT")) return .text;
    if (std.mem.eql(u8, t, "INSTANCE_SWAP")) return .instance_swap;
    if (std.mem.eql(u8, t, "VARIANT")) return .variant;
    return null;
}

/// The Pubd key (on the node) of a node field a variable can drive (`variableField`),
/// for those Pubd has.
fn nodeVarKey(field: []const u8) ?[]const u8 {
    const map = [_][2][]const u8{
        .{ "STACK_SPACING", "gap" },
        .{ "STACK_COUNTER_SPACING", "crossGap" },
        .{ "GRID_COLUMN_GAP", "gap" },
        .{ "GRID_ROW_GAP", "crossGap" },
        .{ "STACK_PADDING_TOP", "padding/0" },
        .{ "STACK_PADDING_RIGHT", "padding/1" },
        .{ "STACK_PADDING_BOTTOM", "padding/2" },
        .{ "STACK_PADDING_LEFT", "padding/3" },
        .{ "RECTANGLE_TOP_LEFT_CORNER_RADIUS", "radius/0" },
        .{ "RECTANGLE_TOP_RIGHT_CORNER_RADIUS", "radius/1" },
        .{ "RECTANGLE_BOTTOM_RIGHT_CORNER_RADIUS", "radius/2" },
        .{ "RECTANGLE_BOTTOM_LEFT_CORNER_RADIUS", "radius/3" },
        .{ "CORNER_RADIUS", "radius" },
        .{ "STROKE_WEIGHT", "stroke/weight" },
        .{ "BORDER_TOP_WEIGHT", "stroke/sides/0" },
        .{ "BORDER_RIGHT_WEIGHT", "stroke/sides/1" },
        .{ "BORDER_BOTTOM_WEIGHT", "stroke/sides/2" },
        .{ "BORDER_LEFT_WEIGHT", "stroke/sides/3" },
        .{ "WIDTH", "width" },
        .{ "HEIGHT", "height" },
        .{ "MIN_WIDTH", "minWidth" },
        .{ "MAX_WIDTH", "maxWidth" },
        .{ "MIN_HEIGHT", "minHeight" },
        .{ "MAX_HEIGHT", "maxHeight" },
        .{ "OPACITY", "opacity" },
        .{ "VISIBLE", "visible" },
        .{ "TEXT_DATA", "text" },
        .{ "X_POSITION", "x" },
        .{ "Y_POSITION", "y" },
        .{ "POLYGON_COUNT", "count" },
    };
    for (map) |e| if (std.mem.eql(u8, e[0], field)) return e[1];
    return null;
}

/// Whether a layer of `src` above layer `from` (0 the node's own record, `k + 1` its
/// `layers[k]`) sets the raw field(s) a `variableField` drives.
fn setAbove(src: Src, from: usize, field: []const u8) bool {
    const map = [_]struct {
        []const u8,
        []const []const u8,
    }{
        .{ "STACK_SPACING", &.{"stackSpacing"} },
        .{ "STACK_COUNTER_SPACING", &.{"stackCounterSpacing"} },
        .{ "GRID_COLUMN_GAP", &.{"gridColumnGap"} },
        .{ "GRID_ROW_GAP", &.{"gridRowGap"} },
        .{ "STACK_PADDING_TOP", &.{"stackVerticalPadding"} },
        .{ "STACK_PADDING_RIGHT", &.{"stackPaddingRight"} },
        .{ "STACK_PADDING_BOTTOM", &.{"stackPaddingBottom"} },
        .{ "STACK_PADDING_LEFT", &.{"stackHorizontalPadding"} },
        .{ "RECTANGLE_TOP_LEFT_CORNER_RADIUS", &.{ "rectangleTopLeftCornerRadius", "cornerRadius" } },
        .{ "RECTANGLE_TOP_RIGHT_CORNER_RADIUS", &.{ "rectangleTopRightCornerRadius", "cornerRadius" } },
        .{ "RECTANGLE_BOTTOM_RIGHT_CORNER_RADIUS", &.{ "rectangleBottomRightCornerRadius", "cornerRadius" } },
        .{ "RECTANGLE_BOTTOM_LEFT_CORNER_RADIUS", &.{ "rectangleBottomLeftCornerRadius", "cornerRadius" } },
        .{ "CORNER_RADIUS", &.{"cornerRadius"} },
        .{ "STROKE_WEIGHT", &.{"strokeWeight"} },
        .{ "BORDER_TOP_WEIGHT", &.{"borderTopWeight"} },
        .{ "BORDER_RIGHT_WEIGHT", &.{"borderRightWeight"} },
        .{ "BORDER_BOTTOM_WEIGHT", &.{"borderBottomWeight"} },
        .{ "BORDER_LEFT_WEIGHT", &.{"borderLeftWeight"} },
        .{ "WIDTH", &.{"size"} },
        .{ "HEIGHT", &.{"size"} },
        .{ "MIN_WIDTH", &.{"minSize"} },
        .{ "MAX_WIDTH", &.{"maxSize"} },
        .{ "MIN_HEIGHT", &.{"minSize"} },
        .{ "MAX_HEIGHT", &.{"maxSize"} },
        .{ "OPACITY", &.{"opacity"} },
        .{ "VISIBLE", &.{"visible"} },
        .{ "TEXT_DATA", &.{"textData"} },
        .{ "FONT_SIZE", &.{"fontSize"} },
        .{ "FONT_FAMILY", &.{"fontName"} },
        .{ "FONT_STYLE", &.{"fontName"} },
        .{ "LINE_HEIGHT", &.{"lineHeight"} },
        .{ "LETTER_SPACING", &.{"letterSpacing"} },
        .{ "PARAGRAPH_SPACING", &.{"paragraphSpacing"} },
        .{ "PARAGRAPH_INDENT", &.{"paragraphIndent"} },
    };
    const raw: []const []const u8 = for (map) |e| {
        if (std.mem.eql(u8, e[0], field)) break e[1];
    } else return false;
    var k = from;
    while (k < src.layers.len) : (k += 1) {
        for (raw) |r| if (src.layers[k].get(r) != null) return true;
    }
    return false;
}

/// The Pubd key (in a text style) of a text field a variable can drive.
fn textVarKey(field: []const u8) ?[]const u8 {
    const map = [_][2][]const u8{
        .{ "FONT_SIZE", "size" },
        .{ "FONT_FAMILY", "family" },
        .{ "FONT_STYLE", "fontStyle" },
        .{ "FONT_VARIATIONS", "weight" },
        .{ "LINE_HEIGHT", "lineHeight" },
        .{ "LETTER_SPACING", "letterSpacing" },
        .{ "PARAGRAPH_SPACING", "paragraphSpacing" },
        .{ "PARAGRAPH_INDENT", "paragraphIndent" },
    };
    for (map) |e| if (std.mem.eql(u8, e[0], field)) return e[1];
    return null;
}

fn jsonString(a: std.mem.Allocator, s: []const u8) ![]const u8 {
    return std.json.Stringify.valueAlloc(a, s, .{});
}

/// A property's value (`ComponentPropValue`) as JSON.
fn propValueJson(a: std.mem.Allocator, pk: m.PropKind, v: ?View) ![]const u8 {
    const x = v orelse return "null";
    switch (pk) {
        .boolean => if (x.getBool("boolValue")) |b| return if (b) "true" else "false",
        .text, .variant => if (x.get("textValue")) |tv| return jsonString(a, tv.getStr("characters") orelse ""),
        .instance_swap => if (guidOf(x.get("guidValue"))) |g| return jsonString(a, try guidText(a, g)),
    }
    return "null";
}

/// Binds the node field a property drives (`VISIBLE`, `TEXT_DATA`,
/// `OVERRIDDEN_SYMBOL_ID`) to property `def`.
fn bindField(a: std.mem.Allocator, b: *m.Bind, field: []const u8, def: u64) !void {
    const id = try guidText(a, def);
    if (std.mem.eql(u8, field, "VISIBLE")) b.visible = id;
    if (std.mem.eql(u8, field, "TEXT_DATA")) b.text = id;
    if (std.mem.eql(u8, field, "OVERRIDDEN_SYMBOL_ID")) b.component = id;
}

/// Applies the property `def` (if the instance sets it) to the node field it drives.
fn applyProp(src: *Src, props: kiwi.Items, def: u64, field: []const u8) void {
    for (0..props.len()) |i| {
        const p = props.at(i);
        if (guidOf(p.get("defID")) != def) continue;
        const v = p.get("value") orelse return;
        if (std.mem.eql(u8, field, "TEXT_DATA")) {
            if (v.get("textValue")) |tv| src.text = tv;
        } else if (std.mem.eql(u8, field, "VISIBLE")) {
            if (v.getBool("boolValue")) |b| src.visible = b;
        } else if (std.mem.eql(u8, field, "OVERRIDDEN_SYMBOL_ID")) {
            if (guidOf(v.get("guidValue"))) |g| src.swap = g;
        }
        return;
    }
}

/// The node's own type, then the flags that make a frame something else.
fn kindOf(src: Src, t: []const u8) ?m.Kind {
    if (std.mem.eql(u8, t, "FRAME")) {
        if (src.boolean("resizeToFit") orelse false) return .group;
        if (src.boolean("isStateGroup") orelse false) return .component_set;
        return .frame;
    }
    const map = .{
        .{ "CANVAS", m.Kind.page },
        .{ "SECTION", m.Kind.frame },
        .{ "SYMBOL", m.Kind.component },
        .{ "INSTANCE", m.Kind.instance },
        // A repeat group.
        .{ "TRANSFORM", m.Kind.group },
        .{ "GROUP", m.Kind.group },
        .{ "RECTANGLE", m.Kind.rectangle },
        .{ "ROUNDED_RECTANGLE", m.Kind.rectangle },
        .{ "ELLIPSE", m.Kind.ellipse },
        .{ "LINE", m.Kind.line },
        .{ "STAR", m.Kind.star },
        .{ "REGULAR_POLYGON", m.Kind.polygon },
        .{ "BOOLEAN_OPERATION", m.Kind.boolean },
        .{ "SLICE", m.Kind.slice },
        .{ "VECTOR", m.Kind.vector },
        .{ "TEXT", m.Kind.text },
        .{ "TEXT_PATH", m.Kind.text },
    };
    inline for (map) |e| if (std.mem.eql(u8, t, e[0])) return e[1];
    return null;
}

fn blendOf(s: []const u8) m.Blend {
    if (std.mem.eql(u8, s, "PASS_THROUGH")) return .pass_through;
    if (std.mem.eql(u8, s, "NORMAL")) return .normal;
    inline for (@typeInfo(m.Blend).@"enum".field_names) |field_name| {
        var buf: [32]u8 = undefined;
        const up = std.ascii.upperString(&buf, field_name);
        if (std.mem.eql(u8, s, up)) return @field(m.Blend, field_name);
    }
    return .normal;
}

/// Auto layout. The file leaves out a primary sizing that hugs and a counter sizing that
/// is fixed (REST reads them the same way); padding is left, top, right, bottom.
/// A grid's primary axis is horizontal; its gaps are `gridColumnGap` and `gridRowGap`
/// (tracks are read by the caller).
fn layoutOf(src: Src, mode: []const u8) m.Layout {
    const main = src.enumName("stackPrimaryAlignItems") orelse "MIN";
    const cross = src.enumName("stackCounterAlignItems") orelse "MIN";
    const grid = std.mem.eql(u8, mode, "GRID");
    const horizontal = grid or std.mem.eql(u8, mode, "HORIZONTAL");
    const primary_hug = !src.is("stackPrimarySizing", "FIXED");
    const counter_hug = std.mem.startsWith(u8, src.enumName("stackCounterSizing") orelse "FIXED", "RESIZE_TO_FIT");
    return .{
        .mode = if (grid) .grid else if (horizontal) .horizontal else .vertical,
        .wrap = src.is("stackWrap", "WRAP"),
        .gap = src.float(if (grid) "gridColumnGap" else "stackSpacing") orelse 0,
        .cross_gap = src.float(if (grid) "gridRowGap" else "stackCounterSpacing") orelse 0,
        .align_content = if (src.is("stackCounterAlignContent", "SPACE_BETWEEN")) .space_between else .auto,
        .strokes_included = src.boolean("bordersTakeSpace") orelse false,
        .padding = .{
            src.float("stackVerticalPadding") orelse 0,
            src.float("stackPaddingRight") orelse 0,
            src.float("stackPaddingBottom") orelse 0,
            src.float("stackHorizontalPadding") orelse 0,
        },
        .main = if (std.mem.eql(u8, main, "CENTER")) .center else if (std.mem.eql(u8, main, "MAX")) .end else if (std.mem.eql(u8, main, "SPACE_BETWEEN")) .space_between else if (std.mem.eql(u8, main, "SPACE_AROUND")) .space_around else if (std.mem.startsWith(u8, main, "SPACE_EVENLY")) .space_evenly else .start,
        .cross = if (std.mem.eql(u8, cross, "CENTER")) .center else if (std.mem.eql(u8, cross, "MAX")) .end else if (std.mem.eql(u8, cross, "BASELINE")) .baseline else .start,
        .width = if ((if (horizontal) primary_hug else counter_hug)) .hug else .fixed,
        .height = if ((if (horizontal) counter_hug else primary_hug)) .hug else .fixed,
    };
}

fn tileAlign(s: []const u8) m.TileAlign {
    if (std.mem.eql(u8, s, "CENTER")) return .center;
    if (std.mem.eql(u8, s, "END")) return .end;
    return .start;
}

fn hConstraint(s: []const u8) m.HConstraint {
    if (std.mem.eql(u8, s, "MAX")) return .right;
    if (std.mem.eql(u8, s, "STRETCH")) return .left_right;
    if (std.mem.eql(u8, s, "CENTER")) return .center;
    if (std.mem.eql(u8, s, "SCALE")) return .scale;
    return .left;
}

fn vConstraint(s: []const u8) m.VConstraint {
    if (std.mem.eql(u8, s, "MAX")) return .bottom;
    if (std.mem.eql(u8, s, "STRETCH")) return .top_bottom;
    if (std.mem.eql(u8, s, "CENTER")) return .center;
    if (std.mem.eql(u8, s, "SCALE")) return .scale;
    return .top;
}

fn textResize(s: []const u8) m.TextResize {
    if (std.mem.eql(u8, s, "HEIGHT")) return .height;
    if (std.mem.eql(u8, s, "WIDTH_AND_HEIGHT")) return .width_and_height;
    if (std.mem.eql(u8, s, "TRUNCATE")) return .truncate;
    return .fixed;
}

/// The weight a style name spells (`Semi Bold` 600, `Black Italic` 900).
pub fn weightOf(style: []const u8) u16 {
    return m.weightOfStyle(style);
}

/// A node's text style: its font, size, spacing and case, as REST spells them.
fn textStyle(src: Src) m.TextStyle {
    var s: m.TextStyle = .{
        .size = src.float("fontSize"),
        .paragraph_spacing = src.float("paragraphSpacing"),
        .paragraph_indent = src.float("paragraphIndent"),
    };
    fontOf(src, &s);
    lineHeightOf(src, &s);
    letterSpacingOf(src, s.size orelse 12, &s);
    caseOf(src, &s);
    if (src.enumName("textDecoration")) |d| s.decoration = decorationOf(d);
    decorationStyleOf(src, &s);
    return s;
}

/// A run's style: what its override entry sets. Sizes in percent resolve against the
/// run's own size, else the node's.
fn runStyle(o: Src, node_src: Src) m.TextStyle {
    var s: m.TextStyle = .{
        .size = o.float("fontSize"),
        .paragraph_spacing = o.float("paragraphSpacing"),
        .paragraph_indent = o.float("paragraphIndent"),
    };
    fontOf(o, &s);
    const size = s.size orelse node_src.float("fontSize") orelse 12;
    lineHeightOf(o, &s);
    letterSpacingOf(o, size, &s);
    caseOf(o, &s);
    if (o.enumName("textDecoration")) |d| s.decoration = decorationOf(d);
    decorationStyleOf(o, &s);
    return s;
}

fn fontOf(src: Src, s: *m.TextStyle) void {
    const f = src.get("fontName") orelse return;
    s.family = f.getStr("family");
    const style = f.getStr("style") orelse "Regular";
    s.font_style = style;
    var w = weightOf(style);
    // A variable font's weight axis wins over the style's name.
    const vars = src.list("fontVariations");
    for (0..vars.len()) |i| {
        const v = vars.at(i);
        const tag = v.getUint("axisTag") orelse 0;
        if (tag == 0x77676874) if (v.getFloat("value")) |x| { // 'wght'
            w = @intFromFloat(std.math.clamp(x, 1, 1000));
        };
    }
    s.weight = w;
    if (std.ascii.findIgnoreCase(style, "italic") != null or std.ascii.findIgnoreCase(style, "oblique") != null) s.italic = true;
}

/// `RAW` is a multiple of the font size, `PERCENT` 100 is the font's own ("auto"),
/// `PIXELS` is pixels.
fn lineHeightOf(src: Src, s: *m.TextStyle) void {
    const lh = src.get("lineHeight") orelse return;
    const v = lh.getFloat("value") orelse return;
    const units = lh.getEnum("units") orelse "RAW";
    if (std.mem.eql(u8, units, "PIXELS")) {
        s.line_height = .{
            .px = v,
        };
    } else if (std.mem.eql(u8, units, "PERCENT")) {
        s.line_height = if (@abs(v - 100) < 1e-4) .auto else .{
            .percent = v,
        };
    } else {
        s.line_height = .{
            .percent = v * 100,
        };
    }
}

/// Letter spacing as pixels (REST's spelling); percent is of the font size.
fn letterSpacingOf(src: Src, size: f32, s: *m.TextStyle) void {
    const ls = src.get("letterSpacing") orelse return;
    const v = ls.getFloat("value") orelse return;
    const units = ls.getEnum("units") orelse "PIXELS";
    s.letter_spacing = .{
        .px = if (std.mem.eql(u8, units, "PERCENT")) v * size / 100 else v,
    };
}

fn caseOf(src: Src, s: *m.TextStyle) void {
    if (src.enumName("textCase")) |c| {
        if (std.mem.eql(u8, c, "UPPER")) s.case = .upper else if (std.mem.eql(u8, c, "LOWER")) s.case = .lower else if (std.mem.eql(u8, c, "TITLE")) s.case = .title else if (std.mem.eql(u8, c, "SMALL_CAPS")) s.case = .small_caps else if (std.mem.eql(u8, c, "SMALL_CAPS_FORCED")) s.case = .small_caps_forced;
    }
    if (src.enumName("fontVariantCaps")) |c| {
        if (std.mem.eql(u8, c, "SMALL")) s.case = .small_caps else if (std.mem.eql(u8, c, "ALL_SMALL")) s.case = .small_caps_forced;
    }
}

fn scatterOf(v: View) m.Scatter {
    return .{
        .gap = v.getFloat("gap") orelse 0,
        .wiggle = v.getFloat("wiggle") orelse 0,
        .angle_jitter = v.getFloat("angularJitter") orelse 0,
        .rotation = v.getFloat("rotation") orelse 0,
        .size_jitter = v.getFloat("sizeJitter") orelse 0,
    };
}

fn decorationStyleOf(src: Src, s: *m.TextStyle) void {
    const d = src.enumName("textDecorationStyle") orelse return;
    s.decoration_style = if (std.mem.eql(u8, d, "WAVY")) .wavy else if (std.mem.eql(u8, d, "DOTTED")) .dotted else .solid;
}

fn decorationOf(d: []const u8) m.Decoration {
    if (std.mem.eql(u8, d, "UNDERLINE")) return .underline;
    if (std.mem.eql(u8, d, "STRIKETHROUGH")) return .strikethrough;
    return .none;
}

fn color(v: View) m.Color {
    return .{
        .r = v.getFloat("r") orelse 0,
        .g = v.getFloat("g") orelse 0,
        .b = v.getFloat("b") orelse 0,
        .a = v.getFloat("a") orelse 1,
    };
}

fn vec(v: View) Vec2 {
    return .{
        .x = v.getFloat("x") orelse 0,
        .y = v.getFloat("y") orelse 0,
    };
}

/// Field `name` of a record as a number: `default` when absent (Kiwi leaves defaults
/// out), null when present but not finite.
fn num(v: View, name: []const u8, default: f32) ?f32 {
    return (v.get(name) orelse return default).float();
}

/// A vector, null when a coordinate is not finite.
fn finiteVec(v: View) ?Vec2 {
    return .{
        .x = num(v, "x", 0) orelse return null,
        .y = num(v, "y", 0) orelse return null,
    };
}

/// A matrix, null when an entry is not finite.
fn finiteMatrix(v: View) ?geom.Affine {
    return .{
        .a = num(v, "m00", 1) orelse return null,
        .c = num(v, "m01", 0) orelse return null,
        .e = num(v, "m02", 0) orelse return null,
        .b = num(v, "m10", 0) orelse return null,
        .d = num(v, "m11", 1) orelse return null,
        .f = num(v, "m12", 0) orelse return null,
    };
}

/// `m00 m01 m02 / m10 m11 m12`: row-major, so `a = m00`, `c = m01`, `e = m02`.
fn matrix(v: View) geom.Affine {
    return .{
        .a = v.getFloat("m00") orelse 1,
        .c = v.getFloat("m01") orelse 0,
        .e = v.getFloat("m02") orelse 0,
        .b = v.getFloat("m10") orelse 0,
        .d = v.getFloat("m11") orelse 1,
        .f = v.getFloat("m12") orelse 0,
    };
}

test "weights from style names" {
    try std.testing.expectEqual(@as(u16, 600), weightOf("Semi Bold"));
    try std.testing.expectEqual(@as(u16, 700), weightOf("Bold Italic"));
    try std.testing.expectEqual(@as(u16, 200), weightOf("ExtraLight"));
    try std.testing.expectEqual(@as(u16, 400), weightOf("Regular"));
    try std.testing.expectEqual(@as(u16, 900), weightOf("Black"));
}

test "garbage is an error, not a crash" {
    const gpa = std.testing.allocator;
    try std.testing.expect(std.meta.isError(import(gpa, "")));
    try std.testing.expect(std.meta.isError(import(gpa, "PK\x05\x06")));
    try std.testing.expect(std.meta.isError(import(gpa, "fig-kiwi\x6a\x00\x00\x00\x01\x00\x00\x00\x00")));
}

test "a group whose size the file leaves unknown fits its children; a lost place comes from the flow" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // A group with only hidden children: no box.
    var hidden = [_]m.Node{.{
        .id = "2",
        .kind = .rectangle,
        .visible = false,
        .size = .{
            .x = 10,
            .y = 10,
        },
    }};
    var empty: m.Node = .{
        .id = "1",
        .kind = .group,
        .children = &hidden,
    };
    fitUnknownGroup(&empty);
    try std.testing.expectEqual(@as(f32, 0), empty.size.x);
    // One with visible children fits them, its origin at their top left.
    var kids = [_]m.Node{ .{
        .id = "4",
        .kind = .rectangle,
        .transform = geom.Affine.translate(5, 7),
        .size = .{
            .x = 10,
            .y = 10,
        },
    }, .{
        .id = "5",
        .kind = .rectangle,
        .transform = geom.Affine.translate(20, 7),
        .size = .{
            .x = 10,
            .y = 4,
        },
    } };
    var g: m.Node = .{
        .id = "3",
        .kind = .group,
        .transform = geom.Affine.translate(100, 100),
        .children = &kids,
    };
    fitUnknownGroup(&g);
    try std.testing.expectEqual(@as(f32, 25), g.size.x);
    try std.testing.expectEqual(@as(f32, 10), g.size.y);
    try std.testing.expectEqual(@as(f32, 105), g.transform.e);
    try std.testing.expectEqual(@as(f32, 0), kids[0].transform.e);

    // In a column: the lost place is after the sibling and the gap.
    var col_kids = [_]m.Node{ .{
        .id = "7",
        .kind = .rectangle,
        .size = .{
            .x = 30,
            .y = 20,
        },
    }, .{
        .id = "8",
        .kind = .group,
        .transform = .{
            .e = std.math.nan(f32),
            .f = std.math.nan(f32),
        },
    } };
    var col: m.Node = .{
        .id = "6",
        .kind = .frame,
        .size = .{
            .x = 30,
            .y = 50,
        },
        .layout = .{
            .mode = .vertical,
            .gap = 10,
        },
        .children = &col_kids,
    };
    var ctx: Ctx = .{
        .a = a,
        .keep = a,
        .s = undefined,
    };
    try ctx.placeUnknown(&col);
    try std.testing.expectEqual(@as(f32, 0), col_kids[1].transform.e);
    try std.testing.expectEqual(@as(f32, 30), col_kids[1].transform.f);
}

fn dumpValue(w: *std.Io.Writer, s: *const kiwi.Schema, v: kiwi.Value, depth: u32) !void {
    switch (v) {
        .bool => |x| try w.print("{}", .{x}),
        .byte => |x| try w.print("{d}", .{x}),
        .int => |x| try w.print("{d}", .{x}),
        .uint => |x| try w.print("{d}", .{x}),
        // JSON has no NaN or infinity: those go as strings.
        .float => |x| if (std.math.isFinite(x)) try w.print("{d}", .{x}) else try w.print("\"{d}\"", .{x}),
        .int64 => |x| try w.print("{d}", .{x}),
        .uint64 => |x| try w.print("{d}", .{x}),
        .string => |x| try w.print("{f}", .{std.json.fmt(x, .{})}),
        .bytes => |x| try w.print("\"<{d} bytes>\"", .{x.len}),
        .@"enum" => |x| try w.print("{f}", .{std.json.fmt(s.defs[x.def].enumName(x.value) orelse "?", .{})}),
        .array => |xs| {
            if (depth >= 4) return w.print("\"<{d} items>\"", .{xs.len});
            try w.writeByte('[');
            for (xs[0..@min(xs.len, 8)], 0..) |x, i| {
                if (i > 0) try w.writeByte(',');
                try dumpValue(w, s, x, depth + 1);
            }
            if (xs.len > 8) try w.print(",\"<{d} more>\"", .{xs.len - 8});
            try w.writeByte(']');
        },
        .record => |r| {
            if (depth >= 4) return w.writeAll("\"<record>\"");
            const d = &s.defs[r.def];
            try w.writeByte('{');
            for (r.entries, 0..) |e, i| {
                if (i > 0) try w.writeByte(',');
                try w.print("{f}:", .{std.json.fmt(d.fields[e.field].name, .{})});
                try dumpValue(w, s, e.value, depth + 1);
            }
            try w.writeByte('}');
        },
    }
}
