//! A document open for viewing, independent of the host: the document, its assets, the
//! fonts, and what a canvas asks of them (pages and frames, tiles, hit tests).
//!
//! The host hands over bytes (a `document.json`, a `.fig`, asset files, font files) and
//! asks for pixels; nothing here reads files or knows about the browser. Images are kept
//! encoded and decoded the first time a render needs them, so opening a document stays
//! cheap and memory grows only with what is looked at.

const std = @import("std");
const m = @import("pubd/model.zig");
const geom = @import("raster/geom.zig");
const mask_mod = @import("raster/mask.zig");
const pix = @import("raster/pixmap.zig");
const render = @import("render/render.zig");
const effects = @import("render/effects.zig");
const text_layout = @import("text/layout.zig");
const fonts_mod = @import("text/fonts.zig");
const pubd_read = @import("pubd/read.zig");
const pubd_blob = @import("pubd/blob.zig");
const pubd_vars = @import("pubd/vars.zig");
const pubd_write = @import("pubd/write.zig");
const sniff = @import("codec/sniff.zig").sniff;
const fig = @import("import/fig/fig.zig");
const figma = @import("import/figma.zig");
const pages_mod = @import("import/pages.zig");
const png = @import("codec/png.zig");
const jpeg = @import("codec/jpeg.zig");
const Image = @import("codec/image.zig").Image;
const Editor = @import("edit/editor.zig").Editor;

const Affine = geom.Affine;
const IRect = mask_mod.IRect;
const Pixmap = pix.Pixmap;

/// Decodes a PNG or JPEG.
pub fn decodeImage(gpa: std.mem.Allocator, bytes: []const u8) !Image {
    if (bytes.len >= 8 and std.mem.eql(u8, bytes[0..8], "\x89PNG\r\n\x1a\n")) return png.decode(gpa, bytes);
    if (bytes.len >= 2 and bytes[0] == 0xFF and bytes[1] == 0xD8) return jpeg.decode(gpa, bytes);
    return error.UnknownImage;
}

/// Which images a pass decodes, and to what detail.
const ImagesOptions = struct {
    /// Node to device: each image is decoded down to the detail it draws at. Without
    /// it, images are decoded in full.
    ctm: ?Affine = null,
    /// Device pixels: subtrees wholly outside are skipped (with `ctm`). Without it,
    /// nothing is skipped.
    clip: ?IRect = null,
};

/// How a tile is drawn.
pub const TileOptions = struct {
    /// Paint the page's background colour under the nodes (otherwise transparent).
    background: bool = false,
};

/// The node under a point and the top-level node it sits in.
pub const Hit = struct {
    node: *const m.Node,
    top: *const m.Node,
    /// The node's box on the page (bounds of its transformed box).
    box: geom.Rect,
};

const Found = struct {
    node: *const m.Node,
    ctm: Affine,
};

/// A page read in pieces: its own fields, and its top-level nodes so far.
pub const PartialPage = struct {
    index: usize,
    arena: std.heap.ArenaAllocator,
    head: m.Node,
    children: []m.Node,
    len: usize = 0,
    /// The page's copies of its components' content, which its instances are written
    /// as changes to (in memory of their own, gone with the page read).
    copies: std.heap.ArenaAllocator,
    bases: ?pubd_read.Bases = null,
};

/// An image a render wanted at mip level `level` (or finer) that the session lacks.
pub const Want = struct {
    hash: []const u8,
    level: u8,
};

pub const Session = struct {
    gpa: std.mem.Allocator,
    doc: ?m.Document = null,
    /// Encoded asset bytes by hash, decoded on first use.
    encoded: std.StringHashMapUnmanaged([]const u8) = .empty,
    /// Decoded images by hash (what the renderer reads).
    images: render.Images = .empty,
    /// Assets that did not decode (not retried).
    bad: std.StringHashMapUnmanaged(void) = .empty,
    /// Asset keys and bytes; reset with the document.
    asset_arena: std.heap.ArenaAllocator,
    /// Bytes the decoded images take.
    image_bytes: usize = 0,
    fonts: text_layout.FontSet = .{},
    /// Font bytes and names; fonts stay across documents.
    font_arena: std.heap.ArenaAllocator,
    /// Buffers handed over by `addFontOwned` and `addAssetOwned`.
    owned_fonts: std.ArrayList([]u8) = .empty,
    owned_assets: std.ArrayList([]u8) = .empty,
    renderer: render.Renderer,
    /// Drops an asset's encoded bytes once it is decoded, for a host that can hand them
    /// over again: `missingForTile` and `missingForNode` say which a render needs. Off,
    /// they stay for the document's life.
    release_encoded: bool = false,
    /// Decoded images beyond this many bytes give back the least recently drawn.
    image_budget: usize = 768 << 20,
    /// The render now (`beginPass`), and the render that last drew each decoded image.
    pass: u32 = 0,
    used: std.StringHashMapUnmanaged(u32) = .empty,
    /// For a document kept page by page: each loaded page's memory (null: not loaded).
    page_arenas: std.ArrayList(?std.heap.ArenaAllocator) = .empty,
    /// What the last refused file said was wrong (`error.NotFinite`).
    problem: pubd_read.Problem = .{},
    /// While `missing…` asks: where the hashes go (nothing is decoded then).
    collecting: ?*std.ArrayList([]const u8) = null,
    collect_gpa: std.mem.Allocator = undefined,
    /// Images are decoded elsewhere (another engine, `pe_decode_image`) and handed over
    /// decoded (`addMipmap`): a render that needs one finer than held notes it in
    /// `wanted` and draws what is held, so a render never decodes.
    decode_elsewhere: bool = false,
    /// What the last render wanted decoded (with `decode_elsewhere`); the hashes point
    /// into the document.
    wanted: std.ArrayList(Want) = .empty,
    /// A page being read in pieces (`beginPage`): it counts as not loaded until `endPage`.
    partial: ?PartialPage = null,
    /// Changes to the open document, undo and redo (`edit/editor.zig`).
    edit: Editor = undefined,
    /// Memory of pages removed by an edit (an undo may still read nothing of it, but the
    /// GPU scene drops what it keeps of their nodes only at its next frame).
    removed_pages: std.ArrayList(std.heap.ArenaAllocator) = .empty,

    /// A session on the heap (the renderer points into it, so it must not move).
    pub fn create(gpa: std.mem.Allocator) !*Session {
        const self = try gpa.create(Session);
        self.* = .{
            .gpa = gpa,
            .asset_arena = .init(gpa),
            .font_arena = .init(gpa),
            .renderer = undefined,
        };
        self.renderer = render.Renderer.init(gpa, &self.images);
        self.renderer.fonts = &self.fonts;
        self.renderer.cull = true;
        self.edit = Editor.init(gpa, self);
        return self;
    }

    pub fn destroy(self: *Session) void {
        self.closeDocument();
        self.edit.deinit();
        self.removed_pages.deinit(self.gpa);
        self.renderer.deinit();
        self.encoded.deinit(self.gpa);
        self.images.deinit(self.gpa);
        self.bad.deinit(self.gpa);
        self.used.deinit(self.gpa);
        self.wanted.deinit(self.gpa);
        self.page_arenas.deinit(self.gpa);
        self.asset_arena.deinit();
        self.fonts.deinit(self.gpa);
        self.font_arena.deinit();
        for (self.owned_fonts.items) |b| self.gpa.free(b);
        self.owned_fonts.deinit(self.gpa);
        self.owned_assets.deinit(self.gpa);
        const gpa = self.gpa;
        gpa.destroy(self);
    }

    /// Drops the document and its assets (fonts stay).
    pub fn closeDocument(self: *Session) void {
        self.cancelPage();
        var it = self.images.valueIterator();
        while (it.next()) |mip| mip.deinit(self.gpa);
        self.images.clearRetainingCapacity();
        self.encoded.clearRetainingCapacity();
        self.bad.clearRetainingCapacity();
        self.used.clearRetainingCapacity();
        self.wanted.clearRetainingCapacity();
        for (self.owned_assets.items) |b| self.gpa.free(b);
        self.owned_assets.clearRetainingCapacity();
        _ = self.asset_arena.reset(.free_all);
        self.image_bytes = 0;
        self.renderer.nodes.clearRetainingCapacity();
        self.edit.reset();
        for (self.page_arenas.items) |*pa| if (pa.*) |*ar| ar.deinit();
        self.page_arenas.clearRetainingCapacity();
        for (self.removed_pages.items) |*ar| ar.deinit();
        self.removed_pages.clearRetainingCapacity();
        if (self.doc) |*d| d.deinit();
        self.doc = null;
    }

    /// Shows nodes built in code (an app's UI) as the session's one page, with no file:
    /// `page`'s children are drawn where they are and stay the caller's (alive while
    /// shown). Called for every frame; images (`addImage`) and fonts stay. What is kept
    /// of a node whose content changed at the same address, or that went, is dropped by
    /// `forgetNode` before the frame is built.
    pub fn showNodes(self: *Session, page: m.Node) !void {
        if (self.doc) |*d| if (d.pages.len == 1 and d.chunks.len == 0) {
            d.pages[0] = page;
            return;
        };
        if (self.doc != null) self.closeDocument();
        var doc: m.Document = .{
            .arena = .init(self.gpa),
        };
        errdefer doc.deinit();
        doc.pages = try doc.arena.allocator().alloc(m.Node, 1);
        doc.pages[0] = page;
        self.doc = doc;
        try self.edit.opened(1);
    }

    /// What frames kept of the node at `addr` (paths, text layouts, polylines, whether it
    /// reads its backdrop) is stale: its content changed there, or it went.
    pub fn forgetNode(self: *Session, addr: usize) !void {
        try self.edit.forgotten.append(self.edit.gpa, addr);
        try self.edit.forgotten_trees.append(self.edit.gpa, addr);
    }

    /// Keeps a decoded picture (`img`, RGBA with straight alpha, taken over) under `key`
    /// for image paints of nodes built in code: never given back to the image budget. A
    /// picture already under `key` is replaced.
    pub fn addImage(self: *Session, key: []const u8, img: *Image) !void {
        const mip = try pix.Mipmap.init(self.gpa, img);
        if (self.images.getPtr(key)) |old| {
            old.deinit(self.gpa);
            old.* = mip;
            return;
        }
        try self.images.put(self.gpa, try self.font_arena.allocator().dupe(u8, key), mip);
    }

    fn adopt(self: *Session, doc: m.Document) !void {
        self.doc = doc;
        // A document in one file has its pages here: bound fields as their variables say.
        if (doc.chunks.len == 0) _ = try pubd_vars.resolveDocument(self.gpa, &self.doc.?);
        try self.page_arenas.appendNTimes(self.gpa, null, doc.chunks.len);
        // Room for every image up front: a decode during a frame never moves the others
        // (a frame may hold pointers to them).
        try self.images.ensureTotalCapacity(self.gpa, @intCast(doc.assets.len * 2 + 16));
        try self.renderer.indexDocument(&self.doc.?);
        try self.edit.opened(doc.pages.len);
    }

    /// An edit added a page at `at`. In a document kept page by page it is loaded (its
    /// nodes live in the editor's memory), or, when not `loaded`, listed only, its nodes
    /// still in its file.
    pub fn insertPageSlot(self: *Session, at: usize, loaded: bool) !void {
        if (self.page_arenas.items.len == 0) return;
        try self.page_arenas.insert(self.gpa, at, if (loaded) std.heap.ArenaAllocator.init(self.gpa) else null);
    }

    /// An edit removed the page at `at`.
    pub fn removePageSlot(self: *Session, at: usize) void {
        if (at >= self.page_arenas.items.len) return;
        const ar = self.page_arenas.orderedRemove(at);
        if (ar) |x| self.removed_pages.append(self.gpa, x) catch {
            var y = x;
            y.deinit();
        };
    }

    /// A document in one file becomes one kept page by page (its pages all loaded).
    pub fn splitPages(self: *Session) !void {
        const d = if (self.doc) |*d| d else return;
        if (self.page_arenas.items.len == d.pages.len) return;
        self.page_arenas.clearRetainingCapacity();
        for (d.pages) |_| try self.page_arenas.append(self.gpa, std.heap.ArenaAllocator.init(self.gpa));
    }

    /// For a document kept page by page: page `i`'s file (a path beside
    /// `document.json`), null when the page is in the document itself.
    pub fn pageFile(self: *const Session, i: usize) ?[]const u8 {
        const d = if (self.doc) |*d| d else return null;
        if (i >= d.chunks.len) return null;
        return d.chunks[i].src;
    }

    /// Whether page `i`'s nodes are here (always, for a document in one file).
    pub fn pageLoaded(self: *const Session, i: usize) bool {
        if (i >= self.page_arenas.items.len) return true;
        return self.page_arenas.items[i] != null;
    }

    /// Reads page `i`'s file (`pageFile`) into memory of its own.
    pub fn loadPage(self: *Session, i: usize, json: []const u8) !void {
        const d = if (self.doc) |*d| d else return error.NoDocument;
        if (i >= self.page_arenas.items.len) return error.NoSuchPage;
        self.unloadPage(i);
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        errdefer arena.deinit();
        var page = try pubd_read.pageFromJson(self.gpa, arena.allocator(), json, .{
            .problem = &self.problem,
        });
        // Bound fields as their variables say now (pubd/SPEC.md "Variables").
        _ = try pubd_vars.resolvePage(self.gpa, d, arena.allocator(), &page);
        d.pages[i] = page;
        self.page_arenas.items[i] = arena;
        try self.reindex();
        try self.edit.pageLoaded(i);
    }

    /// Starts reading page `i` in pieces, so no one call takes long: `head` is its file
    /// without its top-level nodes (an empty `children`), `count` how many there are.
    /// `addPageChild` reads each, `endPage` puts the page in place.
    pub fn beginPage(self: *Session, i: usize, head: []const u8, count: usize) !void {
        if (self.doc == null) return error.NoDocument;
        if (i >= self.page_arenas.items.len) return error.NoSuchPage;
        self.cancelPage();
        self.unloadPage(i);
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        errdefer arena.deinit();
        const page = try pubd_read.pageFromJson(self.gpa, arena.allocator(), head, .{
            .problem = &self.problem,
        });
        const children = try arena.allocator().alloc(m.Node, count);
        var copies: std.heap.ArenaAllocator = .init(self.gpa);
        errdefer copies.deinit();
        const bases = try pubd_read.basesFromJson(copies.allocator(), head);
        self.partial = .{
            .index = i,
            .arena = arena,
            .head = page,
            .children = children,
            .copies = copies,
            .bases = bases,
        };
    }

    /// The next top-level node of page `i`, which `beginPage` started.
    pub fn addPageChild(self: *Session, i: usize, json: []const u8) !void {
        const p = if (self.partial) |*p| p else return error.NoPartialPage;
        if (p.index != i) return error.NoPartialPage;
        if (p.len >= p.children.len) return error.TooManyChildren;
        p.children[p.len] = try pubd_read.childFromJson(self.gpa, p.arena.allocator(), json, if (p.bases) |*b| b else null, .{
            .problem = &self.problem,
        });
        p.len += 1;
    }

    /// `addPageChild` for a node another engine of this build read
    /// (`pubd_blob.encode` of `nodeFromJson`'s node, which checked its numbers).
    pub fn addPageChildBlob(self: *Session, i: usize, blob: []const u8) !void {
        const p = if (self.partial) |*p| p else return error.NoPartialPage;
        if (p.index != i) return error.NoPartialPage;
        if (p.len >= p.children.len) return error.TooManyChildren;
        var r: pubd_blob.Reader = .{
            .bytes = blob,
        };
        p.children[p.len] = try pubd_blob.decode(m.Node, p.arena.allocator(), &r);
        if (r.at != blob.len) return error.BadBlob;
        p.len += 1;
    }

    /// Page `i`, read in pieces, goes in place as `loadPage` puts it.
    pub fn endPage(self: *Session, i: usize) !void {
        const p = self.partial orelse return error.NoPartialPage;
        if (p.index != i) return error.NoPartialPage;
        self.partial = null;
        var page = p.head;
        page.children = p.children[0..p.len];
        var copies = p.copies;
        copies.deinit();
        var arena = p.arena;
        _ = try pubd_vars.resolvePage(self.gpa, &self.doc.?, arena.allocator(), &page);
        self.doc.?.pages[p.index] = page;
        self.page_arenas.items[p.index] = arena;
        try self.reindex();
        try self.edit.pageLoaded(p.index);
    }

    /// Drops a page being read in pieces.
    pub fn cancelPage(self: *Session) void {
        if (self.partial) |*p| {
            p.arena.deinit();
            p.copies.deinit();
        }
        self.partial = null;
    }

    /// Gives back page `i`'s nodes (the page stays listed; its file can be read again).
    /// A page with changes not saved stays.
    pub fn unloadPage(self: *Session, i: usize) void {
        if (i >= self.page_arenas.items.len) return;
        if (self.edit.mustStay(i)) return;
        var ar = self.page_arenas.items[i] orelse return;
        const d = &self.doc.?;
        // The page as read lives in its own memory: its own fields (id, name, background)
        // move to the document's before that memory goes, or the list and the next
        // `document.json` would read freed bytes.
        const head = pages_mod.headOf(d.arena.allocator(), &d.pages[i]) catch return;
        self.edit.pageUnloading(i);
        d.pages[i] = head;
        self.page_arenas.items[i] = null;
        self.reindex() catch {};
        ar.deinit();
    }

    fn reindex(self: *Session) !void {
        self.renderer.nodes.clearRetainingCapacity();
        try self.renderer.indexDocument(&self.doc.?);
    }

    /// Opens a Pubd `document.json`; its assets come separately (`addAsset`). A document
    /// kept page by page opens with no page's nodes: `loadPage` reads them. On
    /// `error.NotFinite`, `problem` says where.
    pub fn loadPubd(self: *Session, json: []const u8) !void {
        self.closeDocument();
        try self.adopt(try pubd_read.fromJson(self.gpa, json, .{
            .problem = &self.problem,
        }));
    }

    /// `loadFig` taking `bytes` over (allocated with the session's allocator; freed with
    /// the document): images stored in the zip unpacked stay where they are, in it.
    pub fn loadFigOwned(self: *Session, bytes: []u8) !void {
        self.closeDocument();
        self.owned_assets.append(self.gpa, bytes) catch |e| {
            self.gpa.free(bytes);
            return e;
        };
        return self.loadFigKeep(bytes);
    }

    /// Opens a `.fig` file (the zip Figma saves, or a bare canvas); its images come with
    /// it. The images Figma stores unpacked point into `bytes`, which must outlive the
    /// document (`loadFigOwned` sees to that).
    pub fn loadFig(self: *Session, bytes: []const u8) !void {
        self.closeDocument();
        return self.loadFigKeep(bytes);
    }

    fn loadFigKeep(self: *Session, bytes: []const u8) !void {
        var result = try fig.import(self.gpa, bytes);
        errdefer result.doc.deinit();
        const a = result.doc.arena.allocator();
        var assets: std.ArrayList(m.Asset) = .empty;
        for (result.images, result.image_bytes) |*im, data| {
            if (data.len == 0) continue;
            var digest: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
            const hex = std.fmt.bytesToHex(digest, .lower);
            im.hash = try a.dupe(u8, &hex);
            // The same image used twice is one asset.
            if (self.encoded.contains(im.hash)) continue;
            const kind = sniff(data);
            try assets.append(a, .{
                .hash = im.hash,
                .type = kind.type,
                .width = kind.width,
                .height = kind.height,
            });
            // The bytes live in the document's arena, as long as the document.
            try self.encoded.put(self.gpa, im.hash, data);
        }
        figma.resolveImages(&result.doc, result.images);
        result.doc.assets = assets.items;
        try self.adopt(result.doc);
    }

    /// The open document as Pubd JSON (`document.json`, as `pe import-fig` writes it),
    /// owned by the caller; its assets' bytes come from `assetBytes`.
    pub fn pubdJson(self: *const Session, gpa: std.mem.Allocator) ![]u8 {
        const d = if (self.doc) |*d| d else return error.NoDocument;
        return pubd_write.toJson(gpa, d);
    }

    /// The fonts the document's texts ask for, by family, as JSON:
    /// `[{"family","styles":[…],"missing"}]` (a missing family lists the styles it lacks); a missing family draws from the stored
    /// layout of the file where there is one, else from the fallback fonts.
    pub fn fontsJson(self: *const Session, gpa: std.mem.Allocator) ![]u8 {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const a = arena.allocator();
        var refs: std.ArrayList(m.FontRef) = .empty;
        if (self.doc) |*d| {
            if (d.fonts.len > 0) {
                try refs.appendSlice(a, d.fonts);
            } else for (d.pages) |*pg| try m.collectFonts(a, pg, &refs);
        }
        const Family = struct {
            family: []const u8,
            styles: std.ArrayList([]const u8) = .empty,
            missing: bool,
        };
        var fams: std.ArrayList(Family) = .empty;
        for (refs.items) |f| {
            const fam = for (fams.items) |*x| {
                if (std.mem.eql(u8, x.family, f.family)) break x;
            } else blk: {
                try fams.append(a, .{
                    .family = f.family,
                    .missing = false,
                });
                break :blk &fams.items[fams.items.len - 1];
            };
            const here = render.Renderer.hasFace(&self.fonts, .{
                .family = f.family,
                .font_style = f.style,
                .weight = f.weight,
                .italic = f.italic,
            }, .{});
            // A family listed as missing names the styles it lacks.
            if (!here and !fam.missing) {
                fam.missing = true;
                fam.styles.clearRetainingCapacity();
            }
            if (here == !fam.missing) try fam.styles.append(a, f.style);
        }
        const Out = struct {
            family: []const u8,
            styles: []const []const u8,
            missing: bool,
        };
        const out = try a.alloc(Out, fams.items.len);
        for (out, fams.items) |*o, f| o.* = .{
            .family = f.family,
            .styles = f.styles.items,
            .missing = f.missing,
        };
        return std.json.Stringify.valueAlloc(gpa, out, .{});
    }

    /// The hashes of the document's assets as a JSON array (what `assetBytes` answers).
    pub fn assetsJson(self: *const Session, gpa: std.mem.Allocator) ![]u8 {
        var list: std.ArrayList([]const u8) = .empty;
        defer list.deinit(gpa);
        if (self.doc) |*d| for (d.assets) |a| try list.append(gpa, a.hash);
        return std.json.Stringify.valueAlloc(gpa, list.items, .{});
    }

    /// An asset's encoded bytes by hash: added by the host or imported with a `.fig`.
    pub fn assetBytes(self: *const Session, hash: []const u8) ?[]const u8 {
        return self.encoded.get(hash);
    }

    /// Adds an asset's encoded bytes (copied) under its hash.
    pub fn addAsset(self: *Session, hash: []const u8, bytes: []const u8) !void {
        const a = self.asset_arena.allocator();
        try self.encoded.put(self.gpa, try a.dupe(u8, hash), try a.dupe(u8, bytes));
    }

    /// `addAsset` taking `bytes` over (allocated with the session's allocator; freed with
    /// the document), so the host's buffer is not copied.
    pub fn addAssetOwned(self: *Session, hash: []const u8, bytes: []u8) !void {
        const a = self.asset_arena.allocator();
        self.owned_assets.append(self.gpa, bytes) catch |e| {
            self.gpa.free(bytes);
            return e;
        };
        try self.encoded.put(self.gpa, try a.dupe(u8, hash), bytes);
    }

    /// Adds a font file (copied); false when it does not parse.
    pub fn addFont(self: *Session, bytes: []const u8, role: fonts_mod.Role) !bool {
        const a = self.font_arena.allocator();
        return fonts_mod.add(&self.fonts, self.gpa, a, try a.dupe(u8, bytes), role);
    }

    /// `addFont` taking `bytes` over (allocated with the session's allocator; freed with
    /// the session), so the host's buffer is not copied.
    pub fn addFontOwned(self: *Session, bytes: []u8, role: fonts_mod.Role) !bool {
        self.owned_fonts.append(self.gpa, bytes) catch |e| {
            self.gpa.free(bytes);
            return e;
        };
        return fonts_mod.add(&self.fonts, self.gpa, self.font_arena.allocator(), bytes, role);
    }

    /// `addFontOwned` under a family and style name of the host's choosing, for a font
    /// whose own names are missing or hidden (some web builds name themselves "" and
    /// "¶"): its faces take `family` and, when given, `style`.
    pub fn addFontOwnedAs(self: *Session, bytes: []u8, role: fonts_mod.Role, family: []const u8, style: ?[]const u8) !bool {
        const before = self.fonts.faces.items.len;
        const vbefore = self.fonts.variable.items.len;
        if (!try self.addFontOwned(bytes, role)) return false;
        const a = self.font_arena.allocator();
        const fam = try a.dupe(u8, family);
        const st = if (style) |x| try a.dupe(u8, x) else null;
        for (self.fonts.faces.items[before..]) |*f| {
            f.family = fam;
            if (st) |x| {
                f.style = x;
                f.italic = f.italic or std.ascii.findIgnoreCase(x, "italic") != null;
            }
        }
        for (self.fonts.variable.items[vbefore..]) |*f| f.family = fam;
        return true;
    }

    pub fn pages(self: *const Session) []const m.Node {
        return if (self.doc) |*d| d.pages else &.{};
    }

    pub fn findNode(self: *const Session, id: []const u8) ?*const m.Node {
        return self.renderer.nodes.get(id);
    }

    /// The pages and their top-level nodes as JSON: names, boxes and the bounds of
    /// everything they paint (world units; effects and overflow included).
    pub fn pagesJson(self: *const Session, gpa: std.mem.Allocator) ![]u8 {
        const FrameJson = struct {
            id: []const u8,
            name: []const u8,
            type: []const u8,
            /// The node's box in page coordinates: x0, y0, x1, y1.
            box: [4]f32,
            /// Everything it may paint, at scale 1.
            bounds: [4]f32,
        };
        const PageJson = struct {
            id: []const u8,
            name: []const u8,
            background: ?[4]f32,
            frames: []FrameJson,
        };
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const list = try a.alloc(PageJson, self.pages().len);
        for (self.pages(), list, 0..) |*pg, *out, pi| {
            // A page kept in its own file and not read: the frames the document lists.
            if (!self.pageLoaded(pi)) {
                const info = self.doc.?.chunks[pi].frames;
                const frames = try a.alloc(FrameJson, info.len);
                for (info, frames) |fi, *f| f.* = .{
                    .id = fi.id,
                    .name = fi.name,
                    .type = @tagName(fi.kind),
                    .box = fi.box,
                    .bounds = fi.bounds,
                };
                out.* = .{
                    .id = pg.id,
                    .name = pg.name,
                    .background = if (pg.background) |bg| .{ bg.r, bg.g, bg.b, bg.a } else null,
                    .frames = frames,
                };
                continue;
            }
            const frames = try a.alloc(FrameJson, pg.children.len);
            for (pg.children, frames) |*c, *f| {
                const box = geom.Rect.transformed(.{
                    .x1 = c.size.x,
                    .y1 = c.size.y,
                }, c.transform);
                const b = render.cullBounds(c, c.transform);
                f.* = .{
                    .id = c.id,
                    .name = c.name,
                    .type = @tagName(c.kind),
                    .box = .{ box.x0, box.y0, box.x1, box.y1 },
                    .bounds = if (b.isEmpty()) .{ 0, 0, 0, 0 } else .{ b.x0, b.y0, b.x1, b.y1 },
                };
            }
            out.* = .{
                .id = pg.id,
                .name = pg.name,
                .background = if (pg.background) |bg| .{ bg.r, bg.g, bg.b, bg.a } else null,
                .frames = frames,
            };
        }
        return std.json.Stringify.valueAlloc(gpa, .{
            .name = if (self.doc) |d| d.name else "",
            .pages = list,
        }, .{});
    }

    /// Renders the part of page `page_index` whose top left is world (`x`, `y`) at
    /// `scale` device pixels per unit into a `w` x `h` pixmap (top left at 0, 0).
    pub fn renderTile(self: *Session, page_index: usize, x: f64, y: f64, scale: f32, w: u32, h: u32, options: TileOptions) !Pixmap {
        const pg = if (page_index < self.pages().len) &self.pages()[page_index] else return error.NoSuchPage;
        self.beginPass();
        var out = try Pixmap.init(self.gpa, .{
            .x1 = @intCast(w),
            .y1 = @intCast(h),
        });
        errdefer out.deinit(self.gpa);
        const r = &self.renderer;
        r.text_bounds.clearRetainingCapacity();
        r.image_bounds.clearRetainingCapacity();
        r.drawn = 0;
        r.culled = 0;
        defer _ = r.frame.reset(.retain_capacity);
        // A background blur reads what lies behind it up to three sigmas away: the tile is
        // drawn with that much more around it (so its blur matches a whole render's),
        // then cut out.
        var margin: f32 = 0;
        for (pg.children) |*c| {
            const at = place(c, x, y, scale);
            margin = @max(margin, backdropReach(c, at.ctm, at.shift(out.rect)));
        }
        const apron: i32 = @intFromFloat(@ceil(@min(margin, max_apron)));
        var work = if (apron > 0) try Pixmap.init(self.gpa, out.rect.outset(apron)) else out;
        defer if (apron > 0) work.deinit(self.gpa);
        if (options.background) if (pg.background) |bg| {
            @memset(work.data, pix.premultiply(bg.r, bg.g, bg.b, bg.a));
        };
        for (pg.children) |*c| {
            // The node draws in its own device coordinates, as an export of it does, onto
            // the tile seen from there: the same numbers, so the same pixels.
            const at = place(c, x, y, scale);
            var view = work;
            view.rect = at.shift(work.rect);
            if (IRect.around(render.cullBounds(c, at.ctm)).intersect(view.rect).isEmpty()) continue;
            try self.ensureImages(c, .{
                .ctm = at.ctm,
                .clip = view.rect,
            });
            try r.drawNode(c, at.ctm, &view);
        }
        if (apron > 0) {
            var row: i32 = 0;
            while (row < @as(i32, @intCast(h))) : (row += 1) @memcpy(out.row(row), work.row(row)[@intCast(apron)..][0..w]);
        }
        return out;
    }

    /// The widest a tile's apron gets, in device pixels (backdrops wider than that blur
    /// a little differently at tile edges).
    const max_apron: f32 = 1024;

    /// Where a top-level node lands on a tile with world (`x`, `y`) at its top left: its
    /// origin is `dx`, `dy` whole device pixels into the tile, plus the fraction in
    /// `ctm`. Worked out in f64 (nodes may sit far from the page's origin).
    pub const Place = struct {
        ctm: Affine,
        dx: i32,
        dy: i32,

        /// A tile rect seen from the node's origin.
        pub fn shift(p: Place, r: IRect) IRect {
            return .{
                .x0 = r.x0 - p.dx,
                .y0 = r.y0 - p.dy,
                .x1 = r.x1 - p.dx,
                .y1 = r.y1 - p.dy,
            };
        }
    };

    pub fn place(c: *const m.Node, x: f64, y: f64, scale: f32) Place {
        const t = c.transform;
        const s: f64 = scale;
        const ox = (@as(f64, t.e) - x) * s;
        const oy = (@as(f64, t.f) - y) * s;
        const big: f64 = 1 << 30;
        const dx = @round(std.math.clamp(ox, -big, big));
        const dy = @round(std.math.clamp(oy, -big, big));
        return .{
            .ctm = .{
                .a = scale * t.a,
                .b = scale * t.b,
                .c = scale * t.c,
                .d = scale * t.d,
                .e = @floatCast(ox - dx),
                .f = @floatCast(oy - dy),
            },
            .dx = @intFromFloat(dx),
            .dy = @intFromFloat(dy),
        };
    }

    /// Renders node `id` the way an export does (`pe render`): its box at `scale`.
    pub fn renderNode(self: *Session, id: []const u8, scale: f32) !Pixmap {
        const n = self.findNode(id) orelse return error.NoSuchNode;
        self.beginPass();
        try self.ensureImages(n, .{
            .ctm = Affine.scaling(scale, scale),
        });
        const r = &self.renderer;
        // Exactly as an export draws: everything.
        const cull = r.cull;
        r.cull = false;
        defer r.cull = cull;
        r.text_bounds.clearRetainingCapacity();
        r.image_bounds.clearRetainingCapacity();
        return r.renderExport(n, scale);
    }

    /// Which part of a node `renderLayer` draws.
    pub const LayerPart = enum(u32) {
        /// The node as a tile draws it.
        whole = 0,
        /// Its drop shadows alone.
        shadows = 1,
        /// Its inner shadows alone.
        inner_shadows = 2,
        /// The mask among its children at `child` and the siblings that mask covers.
        mask_run = 3,
    };

    /// Draws part of node `id` under `ctm` (node space to the layer's device space) into a
    /// pixmap over `rect`: what the GPU canvas takes from the CPU for what it does not
    /// draw itself yet. The same pixels a tile holds there for that part.
    pub fn renderLayer(self: *Session, id: []const u8, part: LayerPart, child: u32, ctm: Affine, rect: IRect) !Pixmap {
        const n = self.findNode(id) orelse return error.NoSuchNode;
        var out = try Pixmap.init(self.gpa, rect);
        errdefer out.deinit(self.gpa);
        self.beginPass();
        try self.ensureImages(n, .{
            .ctm = ctm,
            .clip = rect,
        });
        const r = &self.renderer;
        r.text_bounds.clearRetainingCapacity();
        r.image_bounds.clearRetainingCapacity();
        r.drawn = 0;
        r.culled = 0;
        defer _ = r.frame.reset(.retain_capacity);
        switch (part) {
            .whole => try r.drawNode(n, ctm, &out),
            .shadows => {
                r.shadows_of = n;
                defer r.shadows_of = null;
                try r.drawNode(n, ctm, &out);
            },
            .inner_shadows => try r.drawInnerShadows(n, ctm, &out),
            .mask_run => try r.drawMaskRun(n, child, ctm, &out),
        }
        return out;
    }

    /// Starts a render: images it draws are stamped with it, and only images no later
    /// than the one before may give their memory back.
    pub fn beginPass(self: *Session) void {
        self.pass +%= 1;
        self.wanted.clearRetainingCapacity();
    }

    /// The assets a tile (as `renderTile` takes it) needs whose bytes the session does
    /// not hold: the host hands them over (`addAsset`) before drawing it. The hashes point
    /// into the document; the list is the caller's (`gpa`).
    pub fn missingForTile(self: *Session, gpa: std.mem.Allocator, page_index: usize, x: f64, y: f64, scale: f32, w: u32, h: u32) ![]const []const u8 {
        const pg = if (page_index < self.pages().len) &self.pages()[page_index] else return error.NoSuchPage;
        var list: std.ArrayList([]const u8) = .empty;
        errdefer list.deinit(gpa);
        self.collecting = &list;
        self.collect_gpa = gpa;
        defer self.collecting = null;
        // As much around the tile as a backdrop blur may read.
        const rect = (IRect{
            .x1 = @intCast(w),
            .y1 = @intCast(h),
        }).outset(@intFromFloat(max_apron));
        for (pg.children) |*c| {
            const at = place(c, x, y, scale);
            try self.ensureImages(c, .{
                .ctm = at.ctm,
                .clip = at.shift(rect),
            });
        }
        return list.toOwnedSlice(gpa);
    }

    /// `missingForTile` for `renderNode(id, scale)`.
    pub fn missingForNode(self: *Session, gpa: std.mem.Allocator, id: []const u8, scale: f32) ![]const []const u8 {
        const n = self.findNode(id) orelse return error.NoSuchNode;
        var list: std.ArrayList([]const u8) = .empty;
        errdefer list.deinit(gpa);
        self.collecting = &list;
        self.collect_gpa = gpa;
        defer self.collecting = null;
        try self.ensureImages(n, .{
            .ctm = Affine.scaling(scale, scale),
        });
        return list.toOwnedSlice(gpa);
    }

    /// Decodes the images used by `n` and its descendants that paint inside `clip`
    /// (everything when null), each down to the detail `ctm` (node to device) draws it
    /// at; with no `ctm`, in full.
    fn ensureImages(self: *Session, n: *const m.Node, options: ImagesOptions) !void {
        if (!n.visible) return;
        if (options.ctm) |c| if (options.clip) |cr| if (IRect.around(render.cullBounds(n, c)).intersect(cr).isEmpty()) return;
        const at: ImagesOptions = .{
            .ctm = options.ctm,
        };
        try self.ensurePaintsAt(n.fills, n.size, at);
        try self.ensurePaintsAt(n.strokes, n.size, at);
        if (n.text) |t| for (t.runs) |run| if (run.fills) |fs| try self.ensurePaintsAt(fs, n.size, at);
        for (n.children) |*c| try self.ensureImages(c, .{
            .ctm = if (options.ctm) |m0| m0.mul(c.transform) else null,
            .clip = options.clip,
        });
    }

    /// Decodes the images `paints` use (and those of pattern sources), in full.
    pub fn ensurePaints(self: *Session, paints: []const m.Paint) anyerror!void {
        return self.ensurePaintsAt(paints, .{}, .{});
    }

    /// Decodes an image paint down to the detail it draws at on a node of `size` under
    /// `ctm` (node to device); other paints need nothing.
    pub fn ensurePaintAt(self: *Session, p: *const m.Paint, size: geom.Vec2, ctm: Affine) !void {
        return self.ensurePaintsAt(@as(*const [1]m.Paint, p), size, .{
            .ctm = ctm,
        });
    }

    fn ensurePaintsAt(self: *Session, paints: []const m.Paint, size: geom.Vec2, options: ImagesOptions) anyerror!void {
        for (paints) |*p| {
            if (!p.visible) continue;
            switch (p.kind) {
                .image => try self.ensureImage(p.asset, if (options.ctm) |c| self.levelFor(p, size, c) else 0),
                // A pattern's tile may draw its source at any size: in full.
                .pattern => if (self.findNode(p.source)) |src| try self.ensureImages(src, .{}),
                else => {},
            }
        }
    }

    /// The finest mip level an image paint needs on a node of `size` under `ctm`: the
    /// one its box average reads (`ImageShader.boxLevel`: texels a quarter of the
    /// footprint); 0 (full) when the image's size is unknown or it draws near full size.
    fn levelFor(self: *const Session, p: *const m.Paint, size: geom.Vec2, ctm: Affine) u8 {
        const d = if (self.doc) |*d| d else return 0;
        const a = d.asset(p.asset) orelse return 0;
        if (a.width == 0 or a.height == 0) return 0;
        const n2i = render.imageSpace(p, size, @floatFromInt(a.width), @floatFromInt(a.height)) orelse return 0;
        const det = @abs(ctm.det());
        if (!(det > 0)) return 0;
        const footprint = @sqrt(@abs(n2i.det()) / det);
        if (!std.math.isFinite(footprint) or footprint < 8) return 0;
        return @intFromFloat(@min(@floor(std.math.log2(footprint)) - 2, 24));
    }

    /// Decodes an image down to mip level `level` (keeping finer levels it already has).
    /// While `missing…` asks, notes it instead when its bytes are not here.
    fn ensureImage(self: *Session, hash: []const u8, level: u8) !void {
        if (hash.len == 0 or self.bad.contains(hash)) return;
        if (self.images.getPtr(hash)) |mip| {
            if (self.used.getPtr(hash)) |u| u.* = self.pass;
            if (mip.first <= level) return;
        }
        if (self.decode_elsewhere) return self.want(hash, level);
        const key = self.encoded.getKey(hash) orelse {
            if (self.collecting) |list| {
                for (list.items) |h| if (std.mem.eql(u8, h, hash)) return;
                try list.append(self.collect_gpa, hash);
            }
            return;
        };
        if (self.collecting != null) return;
        const bytes = self.encoded.get(hash).?;
        var img = decodeImage(self.gpa, bytes) catch {
            try self.bad.put(self.gpa, key, {});
            return;
        };
        defer img.deinit(self.gpa);
        var mip = try pix.Mipmap.init(self.gpa, &img);
        mip.dropFinest(self.gpa, level);
        if (self.images.getPtr(hash)) |old| {
            self.image_bytes -= old.bytes();
            old.deinit(self.gpa);
            old.* = mip;
        } else {
            errdefer mip.deinit(self.gpa);
            try self.images.put(self.gpa, key, mip);
        }
        self.image_bytes += mip.bytes();
        try self.used.put(self.gpa, key, self.pass);
        if (self.release_encoded) self.releaseEncoded(key);
        self.evict();
    }

    /// Notes that the render wants `hash` down to `level` (once per image, the finest
    /// level asked).
    fn want(self: *Session, hash: []const u8, level: u8) !void {
        for (self.wanted.items) |*w| if (std.mem.eql(u8, w.hash, hash)) {
            w.level = @min(w.level, level);
            return;
        };
        try self.wanted.append(self.gpa, .{
            .hash = hash,
            .level = level,
        });
    }

    /// Keeps an image decoded elsewhere (`Mipmap.pack`'s bytes) under `hash`, unless one
    /// as fine is held already.
    pub fn addMipmap(self: *Session, hash: []const u8, bytes: []const u8) !void {
        var mip = try pix.Mipmap.unpack(self.gpa, bytes);
        if (self.images.getPtr(hash)) |old| {
            if (old.first <= mip.first) {
                mip.deinit(self.gpa);
                return;
            }
            self.image_bytes -= old.bytes();
            old.deinit(self.gpa);
            old.* = mip;
        } else {
            errdefer mip.deinit(self.gpa);
            const key = try self.asset_arena.allocator().dupe(u8, hash);
            try self.images.put(self.gpa, key, mip);
        }
        self.image_bytes += mip.bytes();
        try self.used.put(self.gpa, self.images.getKey(hash).?, self.pass);
        self.evict();
    }

    /// An asset that did not decode elsewhere: never wanted again.
    pub fn markBad(self: *Session, hash: []const u8) !void {
        if (self.bad.contains(hash)) return;
        try self.bad.put(self.gpa, try self.asset_arena.allocator().dupe(u8, hash), {});
    }

    /// Frees an asset's encoded bytes (decoded now; the host can hand them over again).
    fn releaseEncoded(self: *Session, key: []const u8) void {
        const bytes = self.encoded.get(key) orelse return;
        _ = self.encoded.remove(key);
        for (self.owned_assets.items, 0..) |b, i| if (b.ptr == bytes.ptr) {
            self.gpa.free(b);
            _ = self.owned_assets.swapRemove(i);
            return;
        };
    }

    /// Gives back decoded images, least recently drawn first, until they fit the budget;
    /// never one the current render or the one before drew. The budget gives way to
    /// what a view draws: an image the view needs, given back while the render walks
    /// to it, could not be decoded again (its bytes are released) and would be left out,
    /// and the next frame would give back another (images missing for good).
    fn evict(self: *Session) void {
        while (self.image_bytes > self.image_budget) {
            var oldest: ?[]const u8 = null;
            var at: u32 = std.math.maxInt(u32);
            var it = self.used.iterator();
            while (it.next()) |e| if (e.value_ptr.* != self.pass and e.value_ptr.* != self.pass -% 1 and e.value_ptr.* < at) {
                at = e.value_ptr.*;
                oldest = e.key_ptr.*;
            };
            const key = oldest orelse return;
            _ = self.used.remove(key);
            if (self.images.fetchRemove(key)) |kv| {
                var mip = kv.value;
                self.image_bytes -= mip.bytes();
                mip.deinit(self.gpa);
            }
        }
    }

    /// The node's box on its page.
    pub fn pageBox(self: *Session, n: *const m.Node) geom.Rect {
        return pageBoxOf(self, n);
    }

    /// What a click on `hit` selects, as Figma's canvas does: the layer directly inside
    /// the top-level frame (a frame, component or instance) the point is in, or the
    /// top-level node itself.
    pub fn clickTarget(self: *Session, hit: Hit) ?*const m.Node {
        self.edit.ensureIndexed() catch return null;
        const top = hit.top;
        if (!top.kind.isContainer()) return top;
        var cur = hit.node.id;
        while (self.edit.parents.get(cur)) |p| {
            if (std.mem.eql(u8, p, top.id)) return self.findNode(cur);
            if (p.len == 0) break;
            cur = p;
        }
        return top;
    }

    /// The deepest visible node at world (`x`, `y`) on page `page_index`, topmost first.
    /// Clipping containers hide what lies outside them; a group answers only through its
    /// children.
    pub fn hitTest(self: *const Session, page_index: usize, x: f32, y: f32) ?Hit {
        if (page_index >= self.pages().len) return null;
        const pg = &self.pages()[page_index];
        const p: geom.Vec2 = .{
            .x = x,
            .y = y,
        };
        var k = pg.children.len;
        while (k > 0) {
            k -= 1;
            const top = &pg.children[k];
            if (hitNode(top, .identity, p)) |f| return .{
                .node = f.node,
                .top = top,
                .box = geom.Rect.transformed(.{
                    .x1 = f.node.size.x,
                    .y1 = f.node.size.y,
                }, f.ctm),
            };
        }
        return null;
    }
};

/// The box of node `n` on its page (bounds of its transformed box).
pub fn pageBoxOf(s: *Session, n: *const m.Node) geom.Rect {
    s.edit.ensureIndexed() catch {};
    var t: Affine = .identity;
    var cur = n.id;
    while (s.edit.parents.get(cur)) |p| {
        if (p.len == 0) break;
        const x = s.findNode(cur) orelse break;
        t = x.transform.mul(t);
        cur = p;
    }
    return geom.Rect.transformed(.{
        .x1 = n.size.x,
        .y1 = n.size.y,
    }, t);
}

/// How far behind it (device pixels) the widest background blur on `n` or under it that
/// may paint in `rect` reads.
pub fn backdropReach(n: *const m.Node, ctm: Affine, rect: IRect) f32 {
    if (!n.visible) return 0;
    if (IRect.around(render.cullBounds(n, ctm)).intersect(rect).isEmpty()) return 0;
    var reach: f32 = 0;
    for (n.effects) |e| {
        if (e.visible and e.kind == .background_blur) reach = @max(reach, 3 * effects.blurReach(e) * ctm.maxScale() * render.background_blur_k + 2);
    }
    for (n.children) |*c| reach = @max(reach, backdropReach(c, ctm.mul(c.transform), rect));
    return reach;
}

fn hitNode(n: *const m.Node, parent: Affine, p: geom.Vec2) ?Found {
    if (!n.visible or n.kind == .slice) return null;
    const ctm = parent.mul(n.transform);
    const inv = ctm.invert() orelse return null;
    const lp = inv.apply(p);
    const inside = lp.x >= 0 and lp.y >= 0 and lp.x <= n.size.x and lp.y <= n.size.y;
    if (n.clip and n.kind.isContainer() and !inside) return null;
    if (n.kind != .boolean) {
        if (n.reverse_z) {
            for (n.children) |*c| if (hitNode(c, ctm, p)) |h| return h;
        } else {
            var k = n.children.len;
            while (k > 0) {
                k -= 1;
                const c = &n.children[k];
                if (c.mask != null) continue;
                if (hitNode(c, ctm, p)) |h| return h;
            }
        }
    }
    if (inside and n.kind != .group) return .{
        .node = n,
        .ctm = ctm,
    };
    return null;
}

const test_doc =
    \\{"pubd":0,"name":"t","pages":[{"id":"0:1","type":"page","name":"P","background":"#e5e5e5",
    \\"children":[{"id":"1:1","type":"frame","name":"F","transform":[1,0,0,1,10,20],"size":[16,16],
    \\"fills":[{"type":"solid","color":"#ff0000"}],"clip":true,"children":[{"id":"1:2","type":"ellipse",
    \\"name":"E","transform":[1,0,0,1,3,4],"size":[7,5],"fills":[{"type":"solid","color":"#0000ff80"}]}]},
    \\{"id":"1:3","type":"rectangle","name":"R","transform":[1,0,0,1,40,20],"size":[8,8],
    \\"fills":[{"type":"solid","color":"#00ff00"}]}]}]}
;

test "a tile over a frame equals the frame's export" {
    const gpa = std.testing.allocator;
    var s = try Session.create(gpa);
    defer s.destroy();
    try s.loadPubd(test_doc);
    var exp = try s.renderNode("1:1", 2);
    defer exp.deinit(gpa);
    var tile = try s.renderTile(0, 10, 20, 2, 32, 32, .{});
    defer tile.deinit(gpa);
    try std.testing.expectEqualSlices(pix.Rgba, exp.data, tile.data);
    // The rectangle lies outside the tile and is skipped.
    try std.testing.expectEqual(@as(u32, 2), s.renderer.drawn);
}

test "tiles cover the page and hit tests find the deepest node" {
    const gpa = std.testing.allocator;
    var s = try Session.create(gpa);
    defer s.destroy();
    try s.loadPubd(test_doc);
    var tile = try s.renderTile(0, 0, 0, 1, 64, 64, .{
        .background = true,
    });
    defer tile.deinit(gpa);
    try std.testing.expectApproxEqAbs(@as(f32, 1), tile.at(44, 24)[1], 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 0.898), tile.at(2, 2)[0], 1e-3);
    try std.testing.expectEqualStrings("1:2", s.hitTest(0, 16, 26).?.node.id);
    try std.testing.expectEqualStrings("1:1", s.hitTest(0, 11, 21).?.node.id);
    try std.testing.expectEqualStrings("1:3", s.hitTest(0, 41, 21).?.top.id);
    try std.testing.expect(s.hitTest(0, 100, 100) == null);
    const json = try s.pagesJson(gpa);
    defer gpa.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"frames\":[{\"id\":\"1:1\"") != null);
}

test "the open document comes back as Pubd JSON that opens the same" {
    const gpa = std.testing.allocator;
    var s = try Session.create(gpa);
    defer s.destroy();
    try s.loadPubd(test_doc);
    try s.addAsset("ab", "bytes");
    try std.testing.expectEqualStrings("bytes", s.assetBytes("ab").?);
    const before = try s.pagesJson(gpa);
    defer gpa.free(before);
    const json = try s.pubdJson(gpa);
    defer gpa.free(json);
    try s.loadPubd(json);
    const after = try s.pagesJson(gpa);
    defer gpa.free(after);
    try std.testing.expectEqualStrings(before, after);
    try std.testing.expect(s.assetBytes("ab") == null);
    s.closeDocument();
    try std.testing.expectError(error.NoDocument, s.pubdJson(gpa));
}

test "a document kept page by page opens without its pages and reads one when asked" {
    const gpa = std.testing.allocator;
    var s = try Session.create(gpa);
    defer s.destroy();
    const doc =
        \\{"pubd":0,"name":"t","pages":[{"id":"0:1","type":"page","name":"P","src":"pages/0-1.json",
        \\"frames":[{"id":"1:1","type":"frame","box":[0,0,64,64],"bounds":[0,0,64,64]}]}],
        \\"assets":{"aa":{"type":"image/png","width":64,"height":64}}}
    ;
    const page =
        \\{"id":"0:1","type":"page","name":"P","children":[{"id":"1:1","type":"rectangle","size":[64,64],
        \\"fills":[{"type":"image","asset":"aa","scale":"fill"}]}]}
    ;
    try s.loadPubd(doc);
    try std.testing.expect(!s.pageLoaded(0));
    try std.testing.expectEqualStrings("pages/0-1.json", s.pageFile(0).?);
    // The page list comes from document.json while the page is not read.
    const before = try s.pagesJson(gpa);
    defer gpa.free(before);
    try std.testing.expect(std.mem.indexOf(u8, before, "\"1:1\"") != null);
    try s.loadPage(0, page);
    try std.testing.expect(s.pageLoaded(0));
    try std.testing.expect(s.findNode("1:1") != null);

    // The image is asked for, handed over, drawn small (fine levels left out), and its
    // bytes given back once decoded.
    s.release_encoded = true;
    const need = try s.missingForTile(gpa, 0, 0, 0, 1.0 / 16.0, 8, 8);
    defer gpa.free(need);
    try std.testing.expectEqual(@as(usize, 1), need.len);
    var px: [64 * 64][4]u8 = @splat(.{ 255, 0, 0, 255 });
    const png_bytes = try png.encode(gpa, 64, 64, std.mem.asBytes(&px));
    defer gpa.free(png_bytes);
    try s.addAsset("aa", png_bytes);
    var tile = try s.renderTile(0, 0, 0, 1.0 / 16.0, 8, 8, .{});
    defer tile.deinit(gpa);
    try std.testing.expect(tile.at(2, 2)[0] > 0.9);
    try std.testing.expect(s.images.get("aa").?.first >= 1);
    try std.testing.expect(s.assetBytes("aa") == null);
    // Drawn at full size now: the bytes are asked for again.
    const again = try s.missingForTile(gpa, 0, 0, 0, 1, 64, 64);
    defer gpa.free(again);
    try std.testing.expectEqual(@as(usize, 1), again.len);

    s.unloadPage(0);
    try std.testing.expect(!s.pageLoaded(0));
    try std.testing.expect(s.findNode("1:1") == null);
}

test "images decoded elsewhere: a render notes what it wants and draws what it is given" {
    const gpa = std.testing.allocator;
    var s = try Session.create(gpa);
    defer s.destroy();
    const doc =
        \\{"pubd":0,"name":"t","pages":[{"id":"0:1","type":"page","name":"P",
        \\"children":[{"id":"1:1","type":"rectangle","size":[64,64],
        \\"fills":[{"type":"image","asset":"aa","scale":"fill"}]}]}],
        \\"assets":{"aa":{"type":"image/png","width":64,"height":64}}}
    ;
    try s.loadPubd(doc);
    s.decode_elsewhere = true;
    var px: [64 * 64][4]u8 = @splat(.{ 255, 0, 0, 255 });
    const png_bytes = try png.encode(gpa, 64, 64, std.mem.asBytes(&px));
    defer gpa.free(png_bytes);
    // Bytes handed over are never decoded here: the render only notes the want.
    try s.addAsset("aa", png_bytes);
    var first = try s.renderTile(0, 0, 0, 1.0 / 16.0, 8, 8, .{});
    first.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), s.wanted.items.len);
    try std.testing.expect(s.images.get("aa") == null);
    const level = s.wanted.items[0].level;
    try std.testing.expect(level >= 1);

    // Decoded as another engine would, packed, and handed over: the same chain.
    var img = try decodeImage(gpa, png_bytes);
    defer img.deinit(gpa);
    var mip = try pix.Mipmap.init(gpa, &img);
    defer mip.deinit(gpa);
    mip.dropFinest(gpa, level);
    var packed_bytes: std.ArrayList(u8) = .empty;
    defer packed_bytes.deinit(gpa);
    try mip.pack(gpa, &packed_bytes);
    try s.addMipmap("aa", packed_bytes.items);
    const got = s.images.get("aa").?;
    try std.testing.expectEqual(mip.first, got.first);
    try std.testing.expectEqual(mip.levels.len, got.levels.len);
    try std.testing.expectEqualSlices(u8, mip.levels[0].data, got.levels[0].data);
    var tile = try s.renderTile(0, 0, 0, 1.0 / 16.0, 8, 8, .{});
    defer tile.deinit(gpa);
    try std.testing.expect(tile.at(2, 2)[0] > 0.9);
    try std.testing.expectEqual(@as(usize, 0), s.wanted.items.len);
    // Drawn at full size: wanted finer.
    var big = try s.renderTile(0, 0, 0, 1, 64, 64, .{});
    big.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), s.wanted.items[0].level);
    try s.markBad("aa");
}

test "a page read in pieces is the page read whole" {
    const gpa = std.testing.allocator;
    var s = try Session.create(gpa);
    defer s.destroy();
    const doc =
        \\{"pubd":0,"name":"t","pages":[{"id":"0:1","type":"page","name":"P","src":"pages/0-1.json",
        \\"frames":[{"id":"1:1","type":"frame","box":[0,0,64,64],"bounds":[0,0,64,64]}]}]}
    ;
    const page =
        \\{"id":"0:1", "type":"page","children": [ {"id":"1:1","type":"rectangle","size":[64,64],"name":"a \"[x]\""} ,
        \\ {"id":"1:2","type":"frame","size":[8,8],"children":[{"id":"1:3","type":"ellipse","size":[4,4]}]} ],"name":"P"}
    ;
    try s.loadPubd(doc);
    try s.loadPage(0, page);
    const whole = try s.edit.pageJson(gpa, 0);
    defer gpa.free(whole);
    s.unloadPage(0);

    const spans = try pubd_read.childSpans(gpa, page);
    defer gpa.free(spans);
    try std.testing.expectEqual(@as(usize, 6), spans.len);
    var head: std.ArrayList(u8) = .empty;
    defer head.deinit(gpa);
    try head.appendSlice(gpa, page[0 .. spans[0] + 1]);
    try head.appendSlice(gpa, page[spans[1] - 1 ..]);
    try s.beginPage(0, head.items, (spans.len - 2) / 2);
    try std.testing.expect(!s.pageLoaded(0));
    var k: usize = 2;
    while (k < spans.len) : (k += 2) try s.addPageChild(0, page[spans[k]..spans[k + 1]]);
    try std.testing.expectError(error.NoPartialPage, s.endPage(1));
    try s.endPage(0);
    try std.testing.expect(s.pageLoaded(0));
    try std.testing.expect(s.findNode("1:3") != null);
    const pieced = try s.edit.pageJson(gpa, 0);
    defer gpa.free(pieced);
    try std.testing.expectEqualStrings(whole, pieced);
    // A page started and dropped leaves nothing behind.
    s.unloadPage(0);
    try s.beginPage(0, head.items, 2);
    s.cancelPage();
    try std.testing.expect(!s.pageLoaded(0));
}

test "a page given back keeps its id and name, emoji and all" {
    const gpa = std.testing.allocator;
    var s = try Session.create(gpa);
    defer s.destroy();
    const doc =
        \\{"pubd":0,"name":"t","pages":[
        \\{"id":"41:8905","type":"page","name":"Cover","src":"pages/41-8905.json","frames":[]},
        \\{"id":"0:1","type":"page","name":"\u2705 (1) Stainless Steel Week \ud83d\ude80","src":"pages/0-1.json","frames":[]}]}
    ;
    try s.loadPubd(doc);
    try s.loadPage(0,
        \\{"id":"41:8905","type":"page","name":"Cover","background":"#123456","children":[]}
    );
    try s.loadPage(1,
        \\{"id":"0:1","type":"page","name":"✅ (1) Stainless Steel Week 🚀","children":[]}
    );
    s.unloadPage(0);
    s.unloadPage(1);
    // The memory the pages were read into is reused.
    try s.loadPage(1,
        \\{"id":"0:1","type":"page","name":"✅ (1) Stainless Steel Week 🚀","children":[]}
    );
    try std.testing.expectEqualStrings("41:8905", s.doc.?.pages[0].id);
    try std.testing.expectEqualStrings("Cover", s.doc.?.pages[0].name);
    try std.testing.expectEqualStrings("0:1", s.doc.?.pages[1].id);
    try std.testing.expectEqualStrings("✅ (1) Stainless Steel Week 🚀", s.doc.?.pages[1].name);
    const json = try s.edit.documentJson(gpa);
    defer gpa.free(json);
    var back = try pubd_read.fromJson(gpa, json, .{});
    defer back.deinit();
    try std.testing.expectEqualStrings("41:8905", back.pages[0].id);
    try std.testing.expectEqualStrings("Cover", back.pages[0].name);
    try std.testing.expectEqualStrings("0:1", back.pages[1].id);
    try std.testing.expectEqualStrings("✅ (1) Stainless Steel Week 🚀", back.pages[1].name);
}
