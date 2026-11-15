//! The WASM entry: a small C ABI over `engine.session.Session` for the browser viewer.
//!
//! Memory: the host asks for a buffer (`pe_alloc`), writes bytes into it, passes it to a
//! call and frees it (`pe_free`); calls copy what they keep, except `pe_add_font` and
//! `pe_add_asset`, which take their buffer over (the host must not free it). Answers (JSON or RGBA8
//! pixels) land in one result buffer the host reads through `pe_result_ptr` and
//! `pe_result_len` before the next call, then tells `pe_result_read` (a large answer's
//! memory goes back). Calls that can fail return a negative number and
//! leave the error's name at `pe_error_ptr`/`pe_error_len`.
//!
//! The host provides `env.pe_panic(ptr, len)`, called with the message before a trap.

const std = @import("std");
const engine = @import("publr_engine");

const Session = engine.session.Session;
/// Large blocks as exact page runs that freed pages of any size can serve again.
const wasm_alloc = @import("wasm_alloc.zig");
const gpa = wasm_alloc.allocator;

extern "env" fn pe_panic(ptr: [*]const u8, len: usize) void;

pub const panic = std.debug.FullPanic(struct {
    fn f(msg: []const u8, _: ?usize) noreturn {
        pe_panic(msg.ptr, msg.len);
        @trap();
    }
}.f);

/// The last answer; grows as needed and is reused.
var result: std.ArrayList(u8) = .empty;
var result_w: u32 = 0;
var result_h: u32 = 0;
var err_name: []const u8 = "";

fn fail(e: anyerror) i32 {
    err_name = @errorName(e);
    return -1;
}

fn setResult(bytes: []const u8) i32 {
    result.clearRetainingCapacity();
    result.appendSlice(gpa, bytes) catch |e| return fail(e);
    return @intCast(bytes.len);
}

/// Makes `owned` (allocated with `gpa`) the result, without a copy.
fn adoptResult(owned: []u8) i32 {
    result.deinit(gpa);
    result = .fromOwnedSlice(owned);
    return @intCast(owned.len);
}

/// A result this large is given back once the host has read it; smaller ones keep their
/// room for the next answer.
const result_kept = 1 << 20;

/// Puts a pixmap's RGBA8 (straight alpha) in the result.
fn setPixels(px: *const engine.pixmap.Pixmap) i32 {
    const w = px.rect.width();
    const h = px.rect.height();
    result.clearRetainingCapacity();
    const out = result.addManyAsSlice(gpa, w * h * 4) catch |e| return fail(e);
    px.writeRgba8(px.rect, out);
    result_w = w;
    result_h = h;
    return @intCast(out.len);
}

export fn pe_alloc(len: usize) ?[*]u8 {
    const s = gpa.alloc(u8, len) catch return null;
    return s.ptr;
}

export fn pe_free(ptr: [*]u8, len: usize) void {
    gpa.free(ptr[0..len]);
}

export fn pe_result_ptr() [*]const u8 {
    return result.items.ptr;
}

export fn pe_result_len() usize {
    return result.items.len;
}

/// The host has read the result: a large one's memory is given back.
export fn pe_result_read() void {
    if (result.capacity > result_kept) result.clearAndFree(gpa);
}

/// Width and height of the last pixels answered.
export fn pe_result_width() u32 {
    return result_w;
}

export fn pe_result_height() u32 {
    return result_h;
}

export fn pe_error_ptr() [*]const u8 {
    return err_name.ptr;
}

export fn pe_error_len() usize {
    return err_name.len;
}

export fn pe_session_new() ?*Session {
    return Session.create(gpa) catch null;
}

export fn pe_session_free(s: *Session) void {
    s.destroy();
}

/// Opens a Pubd `document.json`.
export fn pe_load_pubd(s: *Session, ptr: [*]const u8, len: usize) i32 {
    s.loadPubd(ptr[0..len]) catch |e| return failSaying(e, s);
    return 0;
}

/// Opens a `.fig` file's bytes. Takes the buffer over: `ptr` comes from `pe_alloc` and
/// the host does not free it (images Figma stores unpacked stay in it).
export fn pe_load_fig(s: *Session, ptr: [*]u8, len: usize) i32 {
    s.loadFigOwned(ptr[0..len]) catch |e| return fail(e);
    return 0;
}

/// Closes the open document and drops its assets and decoded images (fonts stay).
export fn pe_close(s: *Session) void {
    s.closeDocument();
}

/// The open document as Pubd JSON (`document.json`); its `assets` map names every asset
/// `pe_asset` answers. For a `.fig` this is the import `pe import-fig` writes.
export fn pe_pubd_json(s: *Session) i32 {
    const json = s.pubdJson(gpa) catch |e| {
        if (e == error.NotFinite) if (s.doc) |*d| if (engine.model.findNotFinite(d)) |nf| {
            return failWith(nf.describe(&err_buf));
        };
        return fail(e);
    };
    return adoptResult(json);
}

/// An asset's encoded bytes by hash.
export fn pe_asset(s: *Session, hash: [*]const u8, hash_len: usize) i32 {
    const bytes = s.assetBytes(hash[0..hash_len]) orelse return fail(error.NoSuchAsset);
    return setResult(bytes);
}

/// The zip `pe_zip_open` holds: its bytes (taken over) and entries.
var zip: ?struct {
    bytes: []u8,
    entries: []engine.fig_container.Entry,
} = null;

/// Opens a zip (a `.pubd` file) for reading entry by entry, closing any open one. Takes
/// the buffer over: `ptr` comes from `pe_alloc` and the host does not free it. Answers the
/// entry names as a JSON array, in the order `pe_zip_read` takes them.
export fn pe_zip_open(ptr: [*]u8, len: usize) i32 {
    pe_zip_close();
    const bytes = ptr[0..len];
    const entries = engine.fig_container.zipEntries(gpa, bytes) catch |e| {
        gpa.free(bytes);
        return fail(e);
    };
    zip = .{
        .bytes = bytes,
        .entries = entries,
    };
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(gpa);
    for (entries) |en| names.append(gpa, en.name) catch |e| return fail(e);
    const json = std.json.Stringify.valueAlloc(gpa, names.items, .{}) catch |e| return fail(e);
    return adoptResult(json);
}

/// Entry `index` of the open zip, inflated.
export fn pe_zip_read(index: u32) i32 {
    const z = zip orelse return fail(error.NoZip);
    if (index >= z.entries.len) return fail(error.NoSuchEntry);
    const en = z.entries[index];
    if (en.method == 0) return setResult(en.data);
    const bytes = engine.fig_container.entryBytes(gpa, en) catch |e| return fail(e);
    return adoptResult(@constCast(bytes));
}

/// Closes the open zip and frees its bytes.
export fn pe_zip_close() void {
    const z = zip orelse return;
    gpa.free(z.entries);
    gpa.free(z.bytes);
    zip = null;
}

/// Adds an asset's encoded bytes under its hash (the name in `assets/`). Takes the
/// buffer over: `ptr` comes from `pe_alloc` and the host does not free it.
export fn pe_add_asset(s: *Session, hash: [*]const u8, hash_len: usize, ptr: [*]u8, len: usize) i32 {
    s.addAssetOwned(hash[0..hash_len], ptr[0..len]) catch |e| return fail(e);
    return 0;
}

/// Adds a font file; `role` 0 face, 1 fallback (in the order added), 2 variable. Returns
/// 1 when added, 0 when the font did not parse. Takes the buffer over: `ptr` comes from
/// `pe_alloc` and the host does not free it.
export fn pe_add_font(s: *Session, role: u32, ptr: [*]u8, len: usize) i32 {
    const r = std.enums.fromInt(engine.fonts.Role, role) orelse {
        gpa.free(ptr[0..len]);
        return fail(error.BadRole);
    };
    const ok = s.addFontOwned(ptr[0..len], r) catch |e| return fail(e);
    return @intFromBool(ok);
}

/// The pages and their top-level nodes as JSON (`Session.pagesJson`).
export fn pe_pages(s: *Session) i32 {
    const json = s.pagesJson(gpa) catch |e| return fail(e);
    return adoptResult(json);
}

/// Renders `w` x `h` device pixels of page `page` with world (`x`, `y`) at the top left,
/// `scale` pixels per unit. `flags` bit 0: paint the page background.
export fn pe_render_tile(s: *Session, page: u32, x: f64, y: f64, scale: f32, w: u32, h: u32, flags: u32) i32 {
    var px = s.renderTile(page, x, y, scale, w, h, .{
        .background = flags & 1 != 0,
    }) catch |e| return fail(e);
    defer px.deinit(gpa);
    return setPixels(&px);
}

/// Renders a node the way `pe render` exports it.
export fn pe_render_node(s: *Session, id: [*]const u8, id_len: usize, scale: f32) i32 {
    var px = s.renderNode(id[0..id_len], scale) catch |e| return fail(e);
    defer px.deinit(gpa);
    return setPixels(&px);
}

/// The node at world (`x`, `y`) on page `page` as JSON
/// (`{"id","name","type","top","top_name","box"}`, box on the page), or `null`.
export fn pe_hit_test(s: *Session, page: u32, x: f32, y: f32) i32 {
    const hit = s.hitTest(page, x, y) orelse return setResult("null");
    const json = std.json.Stringify.valueAlloc(gpa, .{
        .id = hit.node.id,
        .name = hit.node.name,
        .type = @tagName(hit.node.kind),
        .top = hit.top.id,
        .top_name = hit.top.name,
        .box = [4]f32{ hit.box.x0, hit.box.y0, hit.box.x1, hit.box.y1 },
    }, .{}) catch |e| return fail(e);
    return adoptResult(json);
}

/// Bytes the engine holds now (what it was given and has not given back); the memory's
/// size (`memory.buffer.byteLength`) never shrinks.
export fn pe_memory_live() usize {
    return wasm_alloc.live;
}

/// Memory and the last render's counts as JSON.
export fn pe_stats(s: *Session) i32 {
    const json = std.json.Stringify.valueAlloc(gpa, .{
        .memory = @wasmMemorySize(0) * std.wasm.page_size,
        .live = wasm_alloc.live,
        .image_bytes = s.image_bytes,
        .images = s.images.count(),
        .drawn = s.renderer.drawn,
        .culled = s.renderer.culled,
    }, .{}) catch |e| return fail(e);
    return adoptResult(json);
}

// The GPU canvas ------------------------------------------------------------------------

const Scene = engine.gpu_scene.Scene;

/// A frame builder for the GPU canvas (one per canvas; it keeps paths between frames).
export fn pe_gpu_new() ?*Scene {
    const sc = gpa.create(Scene) catch return null;
    sc.* = Scene.init(gpa);
    return sc;
}

/// Drops what the frame builder keeps between frames: call when the document changes.
export fn pe_gpu_forget(sc: *Scene) void {
    sc.forget();
}

/// Whether the view is moving: glyph masks and polylines of nearby scales stand in until
/// it settles (then call again with 0 and draw a frame).
export fn pe_gpu_motion(sc: *Scene, on: u32) void {
    sc.motion = on != 0;
}

/// Draws shadows of rectangles and ellipses by formula (1) or always by passes (0), to
/// compare the two.
export fn pe_gpu_formula(on: u32) void {
    engine.gpu_scene.formula_shadows = on != 0;
}

/// New glyph masks a frame may rasterise (0: text as paths only), to compare the routes.
export fn pe_gpu_glyph_budget(n: u32) void {
    engine.gpu_scene.glyph_budget = n;
}

/// WGSL source: 0 the primitives, 1 the path atlas, 2 the canvas, 3 the effect passes,
/// 4 a kept view scaled (stand-ins).
export fn pe_gpu_shader(which: u32) i32 {
    const src = switch (which) {
        0 => engine.gpu_scene.shaders.paint,
        1 => engine.gpu_scene.shaders.atlas,
        2 => engine.gpu_scene.shaders.present,
        3 => engine.gpu_scene.shaders.effects,
        4 => engine.gpu_scene.shaders.scaled,
        else => return fail(error.NoSuchShader),
    };
    return setResult(src);
}

/// Builds the frame for `w` x `h` device pixels of page `page` with world (`x`, `y`) at
/// the top left; answers the address of its header (`docs/gpu.md`).
export fn pe_gpu_page(sc: *Scene, s: *Session, page: u32, x: f64, y: f64, scale: f32, w: u32, h: u32) i32 {
    sc.buildPage(s, page, x, y, scale, w, h) catch |e| return fail(e);
    return @intCast(@intFromPtr(&sc.header));
}

/// Builds the frame of a node the way an export draws it (`w` x `h` at `scale`).
export fn pe_gpu_node(sc: *Scene, s: *Session, id: [*]const u8, id_len: usize, scale: f32, w: u32, h: u32) i32 {
    sc.buildNode(s, id[0..id_len], scale, w, h) catch |e| return fail(e);
    return @intCast(@intFromPtr(&sc.header));
}

/// The address of level `level` of the frame's texture `tex` (RGBA8; level 0 straight,
/// the rest premultiplied); its size in `pe_result_width`/`pe_result_height`.
export fn pe_gpu_texture_level(sc: *Scene, tex: u32, level: u32) i32 {
    const lv = sc.textureLevel(tex, level) orelse return fail(error.NoSuchLevel);
    result_w = lv.w;
    result_h = lv.h;
    return @intCast(@intFromPtr(lv.data.ptr));
}

// Records: a page kept on the GPU in its nodes' units (docs/gpu.md "Records") --------

const Records = engine.gpu_records.Records;

/// A records builder (one per canvas; it keeps text layouts and paths between builds).
export fn pe_rec_new() ?*Records {
    const r = gpa.create(Records) catch return null;
    r.* = Records.init(gpa);
    return r;
}

/// Drops what the builder keeps between builds: call when the document or fonts change.
export fn pe_rec_forget(r: *Records) void {
    r.forget();
}

/// Gives a records builder back (its page is no longer kept, or the page is given back).
export fn pe_rec_free(r: *Records) void {
    r.deinit();
    gpa.destroy(r);
}

/// Writes the records of page `page`; answers the address of their header.
export fn pe_rec_build(r: *Records, s: *Session, page: u32) i32 {
    r.build(s, page) catch |e| return fail(e);
    return @intCast(@intFromPtr(&r.header));
}

/// Starts writing page `page`'s records a few top-level nodes at a time (`pe_rec_step`).
export fn pe_rec_begin(r: *Records, s: *Session, page: u32) i32 {
    r.begin(s, page) catch |e| return fail(e);
    return 0;
}

/// Writes up to `count` more top-level nodes of the page `pe_rec_begin` started: 1 while
/// some are left, else the address of the records' header (the page is written).
export fn pe_rec_step(r: *Records, s: *Session, count: u32) i32 {
    const more = r.step(s, count) catch |e| return fail(e);
    if (more) return 1;
    return @intCast(@intFromPtr(&r.header));
}

/// Brings page `page`'s records up to date after edits (the header's `full`: 1 written
/// whole, 0 top-level nodes added at the ends of the lists, 2 nothing changed).
export fn pe_rec_update(r: *Records, s: *Session, page: u32) i32 {
    r.update(s, page) catch |e| return fail(e);
    return @intCast(@intFromPtr(&r.header));
}

/// A frame's cameras and the top-level nodes in view (and asks for the images in view);
/// answers the address of the frame header.
export fn pe_rec_frame(r: *Records, s: *Session, x: f64, y: f64, scale: f32, w: u32, h: u32) i32 {
    r.frame(s, x, y, scale, w, h) catch |e| return fail(e);
    return @intCast(@intFromPtr(&r.frame_header));
}

var held_info: [4]u32 = .{ 0, 0, 0, 0 };

/// What image `index` holds now: the address of four u32 (its first level of the full
/// chain, the levels held, level 0's width and height); fails when none is held.
export fn pe_rec_held(r: *Records, s: *Session, index: u32) i32 {
    const mip = r.held(s, index) orelse return fail(error.NotHeld);
    held_info = .{ mip.first, @intCast(mip.levels.len), mip.levels[0].w, mip.levels[0].h };
    return @intCast(@intFromPtr(&held_info));
}

/// The address of level `level` of image `index` as held (RGBA8; level 0 straight, the
/// rest premultiplied); its size in `pe_result_width`/`pe_result_height`.
export fn pe_rec_level(r: *Records, s: *Session, index: u32, level: u32) i32 {
    const mip = r.held(s, index) orelse return fail(error.NotHeld);
    if (level >= mip.levels.len) return fail(error.NoSuchLevel);
    const lv = mip.levels[level];
    result_w = lv.w;
    result_h = lv.h;
    return @intCast(@intFromPtr(lv.data.ptr));
}

/// Item `index` of the records drawn by the frame builder `sc` at the last frame's
/// camera (over its whole rect when that is at most `max_px` pixels, else the view and
/// `margin` around it): the address of `records.ItemOut` (rect, matrix, the scene).
export fn pe_rec_item(r: *Records, sc: *Scene, s: *Session, index: u32, w: u32, h: u32, margin: i32, max_px: f64) i32 {
    if (index >= r.items.items.len) return fail(error.NoSuchItem);
    r.buildItem(sc, s, index, w, h, margin, @intFromFloat(max_px)) catch |e| return fail(e);
    return @intCast(@intFromPtr(&r.item_out));
}

/// The id of item `index`'s node (checks).
export fn pe_rec_item_node(r: *Records, index: u32) i32 {
    if (index >= r.item_nodes.items.len) return fail(error.NoSuchItem);
    return setResult(r.item_nodes.items[index].node.id);
}

/// The records' WGSL.
export fn pe_rec_shader() i32 {
    return setResult(engine.gpu_records.shader);
}

/// Draws part of node `id` (`Session.LayerPart`) under the matrix (a, b, c, d, e, f) into
/// the device rect (`x0`, `y0`, `w`, `h`): premultiplied RGBA8 in the result. What the GPU
/// canvas takes from the CPU.
export fn pe_render_layer(s: *Session, id: [*]const u8, id_len: usize, part: u32, child: u32, a: f32, b: f32, c: f32, d: f32, e: f32, f: f32, x0: i32, y0: i32, w: u32, h: u32) i32 {
    const p = std.enums.fromInt(engine.session.Session.LayerPart, part) orelse return fail(error.BadPart);
    var px = s.renderLayer(id[0..id_len], p, child, .{
        .a = a,
        .b = b,
        .c = c,
        .d = d,
        .e = e,
        .f = f,
    }, .{
        .x0 = x0,
        .y0 = y0,
        .x1 = x0 + @as(i32, @intCast(w)),
        .y1 = y0 + @as(i32, @intCast(h)),
    }) catch |err| return fail(err);
    defer px.deinit(gpa);
    result.clearRetainingCapacity();
    const out = result.addManyAsSlice(gpa, w * h * 4) catch |err| return fail(err);
    for (px.data, 0..) |v, i| {
        inline for (0..4) |k| out[i * 4 + k] = @intFromFloat(@round(std.math.clamp(v[k], 0, 1) * 255));
    }
    result_w = w;
    result_h = h;
    return @intCast(out.len);
}

// ---------------------------------------------------------------- pages, assets, import

/// A failure's message when it says more than its name (`pe_error_*` answer it).
var err_buf: [256]u8 = undefined;

fn failWith(msg: []const u8) i32 {
    err_name = msg;
    return -1;
}

/// `fail`, with the file's problem for `error.NotFinite`.
fn failSaying(e: anyerror, s: *Session) i32 {
    if (e == error.NotFinite and s.problem.len > 0) {
        const msg = std.fmt.bufPrint(&err_buf, "NotFinite: {s}", .{s.problem.message()}) catch return fail(e);
        return failWith(msg);
    }
    return fail(e);
}

fn setJson(v: anytype) i32 {
    const json = std.json.Stringify.valueAlloc(gpa, v, .{}) catch |e| return fail(e);
    return adoptResult(json);
}

/// The document's asset hashes as a JSON array.
export fn pe_assets(s: *Session) i32 {
    const json = s.assetsJson(gpa) catch |e| return fail(e);
    return adoptResult(json);
}

/// Page `page`'s file in a document kept page by page (`pages/<id>.json`), "" when the
/// page is in the document; whether its nodes are loaded, and then the changes they have
/// had (`edits`): `{"src","loaded","edits"}`.
export fn pe_page_file(s: *Session, page: u32) i32 {
    const pages = s.pages();
    return setJson(.{
        .src = s.pageFile(page) orelse "",
        .loaded = s.pageLoaded(page),
        .edits = if (page < pages.len and s.pageLoaded(page)) pages[page].edits else 0,
    });
}

/// Reads page `page`'s file.
export fn pe_load_page(s: *Session, page: u32, ptr: [*]const u8, len: usize) i32 {
    s.loadPage(page, ptr[0..len]) catch |e| return failSaying(e, s);
    return 0;
}

/// Gives back page `page`'s nodes.
export fn pe_unload_page(s: *Session, page: u32) void {
    s.unloadPage(page);
}

/// Where a page file's top-level nodes are (`pubd_read.childSpans`), as a JSON array:
/// the `children` array's `[` and end, then each node's start and end. Needs no session:
/// a worker finds them for the engine that reads the page.
export fn pe_child_spans(ptr: [*]const u8, len: usize) i32 {
    const spans = engine.pubd_read.childSpans(gpa, ptr[0..len]) catch |e| return fail(e);
    defer gpa.free(spans);
    return setJson(spans);
}

/// Starts reading page `page` in pieces: its file less its top-level nodes, and how many.
export fn pe_begin_page(s: *Session, page: u32, ptr: [*]const u8, len: usize, count: u32) i32 {
    s.beginPage(page, ptr[0..len], count) catch |e| return failSaying(e, s);
    return 0;
}

/// The next top-level node of page `page`, being read in pieces.
export fn pe_add_page_child(s: *Session, page: u32, ptr: [*]const u8, len: usize) i32 {
    s.addPageChild(page, ptr[0..len]) catch |e| return failSaying(e, s);
    return 0;
}

/// A top-level node's JSON read here and handed over as bytes for another engine of this
/// build (`pe_add_page_child_blob`): a render worker reads a big page's nodes for the
/// engine that draws, several workers at once.
export fn pe_node_blob(ptr: [*]const u8, len: usize) i32 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var problem: engine.pubd_read.Problem = .{};
    const bases = if (node_bases) |*b| b else null;
    const n = engine.pubd_read.childFromJson(gpa, arena.allocator(), ptr[0..len], bases, .{
        .problem = &problem,
    }) catch |e| return fail(e);
    result.clearRetainingCapacity();
    engine.pubd_blob.encode(gpa, &result, n) catch |e| return fail(e);
    return @intCast(result.items.len);
}

var node_copies: std.heap.ArenaAllocator = .init(gpa);
var node_bases: ?engine.pubd_read.Bases = null;

/// The page whose top-level nodes `pe_node_blob` reads next: its file less those nodes
/// (its copies of its components' content are what its instances are written against).
export fn pe_node_page(ptr: [*]const u8, len: usize) i32 {
    node_bases = null;
    _ = node_copies.reset(.free_all);
    node_bases = engine.pubd_read.basesFromJson(node_copies.allocator(), ptr[0..len]) catch |e| return fail(e);
    return 0;
}

/// The next top-level node of page `page`, read elsewhere (`pe_node_blob`).
export fn pe_add_page_child_blob(s: *Session, page: u32, ptr: [*]const u8, len: usize) i32 {
    s.addPageChildBlob(page, ptr[0..len]) catch |e| return fail(e);
    return 0;
}

/// Page `page`, read in pieces, goes in place.
export fn pe_end_page(s: *Session, page: u32) i32 {
    s.endPage(page) catch |e| return fail(e);
    return 0;
}

/// Drops a page being read in pieces.
export fn pe_cancel_page(s: *Session) void {
    s.cancelPage();
}

/// Images are decoded by the host elsewhere (`on` 1): a render draws what is held and
/// notes what it wanted finer (`pe_take_wanted`); `pe_add_mipmap` hands decoded ones over.
export fn pe_decode_elsewhere(s: *Session, on: u32) void {
    s.decode_elsewhere = on != 0;
}

/// What renders wanted decoded since the last take (or the last pass began): a JSON array
/// of [hash, level]. Taken: the list starts empty again, so a render that follows (an
/// item's picture) tells only what it wanted itself.
export fn pe_take_wanted(s: *Session) i32 {
    result.clearRetainingCapacity();
    result.append(gpa, '[') catch |e| return fail(e);
    for (s.wanted.items, 0..) |w, i| {
        const sep: []const u8 = if (i == 0) "[\"" else ",[\"";
        result.print(gpa, "{s}{s}\",{d}]", .{ sep, w.hash, w.level }) catch |e| return fail(e);
    }
    result.append(gpa, ']') catch |e| return fail(e);
    s.wanted.clearRetainingCapacity();
    return @intCast(result.items.len);
}

/// Decodes an image file (PNG or JPEG) into its mip chain from level `level` down, as
/// `pe_add_mipmap` takes it (`Mipmap.pack`). Needs no session: a worker decodes for
/// the engine that draws.
export fn pe_decode_image(ptr: [*]const u8, len: usize, level: u32) i32 {
    var img = engine.session.decodeImage(gpa, ptr[0..len]) catch |e| return fail(e);
    defer img.deinit(gpa);
    var mip = engine.pixmap.Mipmap.init(gpa, &img) catch |e| return fail(e);
    defer mip.deinit(gpa);
    mip.dropFinest(gpa, @intCast(@min(level, 255)));
    result.clearRetainingCapacity();
    mip.pack(gpa, &result) catch |e| return fail(e);
    return @intCast(result.items.len);
}

/// Keeps a decoded image (`pe_decode_image`'s bytes) under its hash.
export fn pe_add_mipmap(s: *Session, hash: [*]const u8, hash_len: usize, ptr: [*]const u8, len: usize) i32 {
    s.addMipmap(hash[0..hash_len], ptr[0..len]) catch |e| return fail(e);
    return 0;
}

/// An asset that could not be decoded elsewhere: never wanted again.
export fn pe_mark_bad(s: *Session, hash: [*]const u8, hash_len: usize) i32 {
    s.markBad(hash[0..hash_len]) catch |e| return fail(e);
    return 0;
}

/// Drops assets' encoded bytes once decoded (`on` 1): the host hands them over again
/// when `pe_missing_*` names them. `budget` (bytes, 0: keep) caps decoded images.
export fn pe_lazy_assets(s: *Session, on: u32, budget: u32) void {
    s.release_encoded = on != 0;
    if (budget > 0) s.image_budget = budget;
}

/// The assets a tile (as `pe_render_tile` takes it) needs whose bytes the session lacks,
/// as a JSON array of hashes.
export fn pe_missing_tile(s: *Session, page: u32, x: f64, y: f64, scale: f32, w: u32, h: u32) i32 {
    const list = s.missingForTile(gpa, page, x, y, scale, w, h) catch |e| return fail(e);
    defer gpa.free(list);
    return setJson(list);
}

/// `pe_missing_tile` for `pe_render_node`.
export fn pe_missing_node(s: *Session, id: [*]const u8, id_len: usize, scale: f32) i32 {
    const list = s.missingForNode(gpa, id[0..id_len], scale) catch |e| return fail(e);
    defer gpa.free(list);
    return setJson(list);
}

/// The `.fig` import in progress (one at a time): `pe_import_open`, then
/// `pe_import_image` per `images/<ref>`, `pe_import_page` per page, `pe_import_document`.
var job: ?*engine.fig_stream.Job = null;

/// Where a zip's central directory is, from the file's last bytes (`max_tail`, or the
/// whole file when shorter): `{"offset","size","count"}`.
export fn pe_zip_directory(ptr: [*]const u8, len: usize, file_size: f64) i32 {
    const d = engine.fig_container.findDirectory(ptr[0..len], @intFromFloat(file_size)) catch |e| return fail(e);
    return setJson(.{
        .offset = d.offset,
        .size = d.size,
        .count = d.count,
        .tail = engine.fig_container.max_tail,
    });
}

/// The entries a central directory lists: `[{"name","method","csize","size","local"}]`.
export fn pe_zip_list(ptr: [*]const u8, len: usize, count: f64) i32 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const items = engine.fig_container.listDirectory(arena.allocator(), ptr[0..len], @intFromFloat(count)) catch |e| return fail(e);
    return setJson(items);
}

/// Starts importing a `.fig` from its `canvas.fig` and `meta.json` (may be empty): the
/// page count as JSON `{"pages","name"}`.
export fn pe_import_open(canvas: [*]const u8, canvas_len: usize, meta: [*]const u8, meta_len: usize) i32 {
    if (job) |j| j.destroy();
    job = null;
    const j = engine.fig_stream.Job.create(gpa, canvas[0..canvas_len], if (meta_len > 0) meta[0..meta_len] else null) catch |e| return fail(e);
    job = j;
    return setJson(.{
        .pages = j.pageCount(),
        .name = j.im.name,
    });
}

/// Whether the import needs `images/<ref>` (the file names it): 1 or 0.
export fn pe_import_wants(ref: [*]const u8, ref_len: usize) i32 {
    const j = job orelse return fail(error.NoImport);
    const yes = j.im.namesImage(ref[0..ref_len]) catch |e| return fail(e);
    return @intFromBool(yes);
}

/// Takes the bytes of `images/<ref>` (not kept): answers the asset's hash, its file name.
export fn pe_import_image(ref: [*]const u8, ref_len: usize, ptr: [*]const u8, len: usize) i32 {
    const j = job orelse return fail(error.NoImport);
    const hash = j.addImage(ref[0..ref_len], ptr[0..len]) catch |e| return fail(e);
    return setResult(hash);
}

/// Page `page`'s file: `{"path"}` here, its JSON next (`pe_import_page_json`).
var page_json: []u8 = &.{};

export fn pe_import_page(page: u32) i32 {
    const j = job orelse return fail(error.NoImport);
    gpa.free(page_json);
    page_json = &.{};
    const pg = j.pageJson(gpa, page) catch |e| return fail(e);
    page_json = pg.json;
    return setResult(pg.path);
}

/// The JSON of the page `pe_import_page` built (then freed).
export fn pe_import_page_json() i32 {
    defer {
        gpa.free(page_json);
        page_json = &.{};
    }
    return setResult(page_json);
}

/// `document.json`, after every page; then the import ends.
export fn pe_import_document() i32 {
    const j = job orelse return fail(error.NoImport);
    defer {
        j.destroy();
        job = null;
    }
    const json = j.documentJson(gpa) catch |e| return fail(e);
    return adoptResult(json);
}

/// The fonts the document asks for and whether each family is here (`Session.fontsJson`).
export fn pe_fonts(s: *Session) i32 {
    const json = s.fontsJson(gpa) catch |e| return fail(e);
    return adoptResult(json);
}

/// Every face the session can draw text with (the fonts list of a text's properties):
/// `[{"family","style","weight","italic"}]`, variable fonts at their default instance too.
export fn pe_font_faces(s: *Session) i32 {
    const Face = struct {
        family: []const u8,
        style: []const u8,
        weight: u16,
        italic: bool,
    };
    var list: std.ArrayList(Face) = .empty;
    defer list.deinit(gpa);
    for ([_][]const engine.layout.FontSet.Face{ s.fonts.faces.items, s.fonts.variable.items }) |faces| {
        for (faces) |f| list.append(gpa, .{
            .family = f.family,
            .style = f.style,
            .weight = f.weight,
            .italic = f.italic,
        }) catch |e| return fail(e);
    }
    return setJson(list.items);
}

/// What a font file holds: `{"faces":[{"family","style","weight","italic"}],"axes":[…]}`.
export fn pe_font_info(ptr: [*]const u8, len: usize) i32 {
    const json = engine.font_info.json(gpa, ptr[0..len]) catch |e| return fail(e);
    return adoptResult(json);
}

/// `pe_add_font` under a family (and style, when `style_len` > 0) the host names, for a
/// font whose own names are missing or hidden.
export fn pe_add_font_as(s: *Session, role: u32, ptr: [*]u8, len: usize, family: [*]const u8, family_len: usize, style: [*]const u8, style_len: usize) i32 {
    const r = std.enums.fromInt(engine.fonts.Role, role) orelse {
        gpa.free(ptr[0..len]);
        return fail(error.BadRole);
    };
    const ok = s.addFontOwnedAs(ptr[0..len], r, family[0..family_len], if (style_len > 0) style[0..style_len] else null) catch |e| return fail(e);
    return @intFromBool(ok);
}

// Editing ---------------------------------------------------------------------------------
//
// The engine on the canvas's thread edits; the render workers replay what it did. After
// each call that changes the document, `pe_edit_out` answers what changed (the changes
// in order with their pages, the page rects they painted, whether the page list changed,
// whether undo and redo can run, what the history holds), for the host to hand the
// changes to the workers (`pe_edit_replay`), redraw, and save.

/// Applies changes (one change object or an array; `edit/change.zig` and
/// `Editor.apply` for the forms) in the open step, or a step of their own.
export fn pe_edit_apply(s: *Session, ptr: [*]const u8, len: usize) i32 {
    s.edit.apply(ptr[0..len]) catch |e| return fail(e);
    return 0;
}

/// Starts a step: what is applied until the matching `pe_edit_commit` undoes as one.
export fn pe_edit_begin(s: *Session) i32 {
    s.edit.begin() catch |e| return fail(e);
    return 0;
}

export fn pe_edit_commit(s: *Session) i32 {
    s.edit.commit() catch |e| return fail(e);
    return 0;
}

/// Ends the open step by undoing it (Escape during a drag).
export fn pe_edit_cancel(s: *Session) i32 {
    s.edit.cancel() catch |e| return fail(e);
    return 0;
}

/// Holds layers in their auto layouts for the open step, a JSON array of ids (`[]` lets
/// go): each keeps its place in the flow while a drag moves it.
export fn pe_edit_hold(s: *Session, ptr: [*]const u8, len: usize) i32 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const ids = std.json.parseFromSliceLeaky([]const []const u8, arena.allocator(), ptr[0..len], .{}) catch |e| return fail(e);
    s.edit.hold(ids) catch |e| return fail(e);
    return 0;
}

/// The selection now, a JSON array of ids: steps keep it to put back.
export fn pe_edit_select(s: *Session, ptr: [*]const u8, len: usize) i32 {
    s.edit.setSelection(ptr[0..len]) catch |e| return fail(e);
    return 0;
}

/// Undoes the last step: `{"selection":[...],"page":n}` (`page` -1: the document), or
/// `null` when there is nothing to undo.
export fn pe_undo(s: *Session) i32 {
    const r = s.edit.undo() catch |e| return fail(e);
    return restored(r);
}

/// Redoes the last step undone, as `pe_undo` answers.
export fn pe_redo(s: *Session) i32 {
    const r = s.edit.redo() catch |e| return fail(e);
    return restored(r);
}

fn restored(r: ?engine.edit.Editor.Restored) i32 {
    const x = r orelse return setResult("null");
    result.clearRetainingCapacity();
    result.print(gpa, "{{\"selection\":{s},\"page\":{d}}}", .{ x.selection, x.page }) catch |e| return fail(e);
    return @intCast(result.items.len);
}

/// What changed since the last call (`Editor.takeOut`), and clears it.
export fn pe_edit_out(s: *Session) i32 {
    const json = s.edit.takeOut(gpa) catch |e| return fail(e);
    return adoptResult(json);
}

/// Applies changes another engine made (`pe_edit_out`'s `changes`), as they are.
export fn pe_edit_replay(s: *Session, ptr: [*]const u8, len: usize) i32 {
    s.edit.replay(ptr[0..len]) catch |e| return fail(e);
    return 0;
}

/// New node ids are `<n>:<k>`: a number of the host's choosing per editing session, so
/// ids made in different sessions never meet.
export fn pe_edit_seed(s: *Session, n: u32) void {
    s.edit.id_session = n;
}

/// Node `id` for a properties panel (`Editor.nodeInfo`): its Pubd fields, place, box,
/// and the instance it is in with what it overrides.
export fn pe_node_info(s: *Session, id: [*]const u8, id_len: usize) i32 {
    const json = s.edit.nodeInfo(gpa, id[0..id_len]) catch |e| return fail(e);
    return adoptResult(json);
}

/// Component or component set `id` as `document.json`'s `components` lists it, read
/// from its node when its page is loaded, or `null`.
export fn pe_component(s: *Session, id: [*]const u8, id_len: usize) i32 {
    const json = s.edit.componentJson(gpa, id[0..id_len]) catch |e| return fail(e);
    return adoptResult(json);
}

/// The node a click at world (`x`, `y`) on page `page` selects: `mode` 0 the deepest
/// (Cmd+click), 1 as a click does (the layer directly inside the top-level frame, or the
/// top-level node). JSON as `pe_hit_test`, or `null`.
export fn pe_hit_node(s: *Session, page: u32, x: f32, y: f32, mode: u32) i32 {
    const hit = s.hitTest(page, x, y) orelse return setResult("null");
    var n = hit.node;
    if (mode == 1) n = s.clickTarget(hit) orelse hit.node;
    const box = s.pageBox(n);
    const json = std.json.Stringify.valueAlloc(gpa, .{
        .id = n.id,
        .name = n.name,
        .type = @tagName(n.kind),
        .top = hit.top.id,
        .top_name = hit.top.name,
        .box = [4]f32{ box.x0, box.y0, box.x1, box.y1 },
    }, .{}) catch |e| return fail(e);
    return adoptResult(json);
}

/// Node `id` with its whole subtree as Pubd JSON (numbers exact): what a copy keeps, to
/// insert again on paste or duplicate.
export fn pe_node_json(s: *Session, id: [*]const u8, id_len: usize) i32 {
    s.edit.ensureIndexed() catch |e| return fail(e);
    const n = s.edit.node(id[0..id_len]) orelse return fail(error.NoSuchNode);
    const json = engine.pubd_write.nodeJson(gpa, n, .{}) catch |e| return fail(e);
    return adoptResult(json);
}

/// Page `page`'s layer tree for the layers panel and the canvas marks, in the binary form
/// `edit/tree.zig` describes; without its JSON when that hashes to `known`, or (`same` 1)
/// when the caller knows it is the one it holds.
export fn pe_page_tree(s: *Session, page: u32, known: u32, same: u32) i32 {
    engine.edit_tree.pageTree(gpa, s, page, known, same != 0, &result) catch |e| return fail(e);
    return @intCast(result.items.len);
}

/// The deepest layer at world (`x`, `y`) on page `page` by its real shape, hidden and
/// locked layers skipped (`edit/tree.zig` `hit`); `tol` how near counts, in page units.
/// Its id, or `null`.
export fn pe_hit_shape(s: *Session, page: u32, x: f32, y: f32, tol: f32) i32 {
    const n = engine.edit_tree.hit(gpa, s, page, .{
        .x = x,
        .y = y,
    }, tol) orelse return setResult("null");
    const json = std.json.Stringify.valueAlloc(gpa, n.id, .{}) catch |e| return fail(e);
    return adoptResult(json);
}

// ---------------------------------------------------------------- variables

/// The document's variable collections and variables (`Editor.variablesJson`):
/// `{"collections":[{id, name, modes, ...}],"variables":[{id, name, collection, type,
/// values, ...}]}`. Changing them goes through `pe_edit_apply` (`variable`, `collection`
/// changes; bindings are node keys: `vars`, `modes`, a paint's `var`, ...).
export fn pe_variables(s: *Session) i32 {
    const json = s.edit.variablesJson(gpa) catch |e| return fail(e);
    return adoptResult(json);
}

/// What variable `ref` (an id, or `key:<library key>`) is worth at node `id` in the modes
/// the node is in (`id` empty: every collection in its default mode): `{"value": ...}`.
export fn pe_variable_value(s: *Session, id: [*]const u8, id_len: usize, ref: [*]const u8, ref_len: usize) i32 {
    const json = s.edit.variableValue(gpa, id[0..id_len], ref[0..ref_len]) catch |e| return fail(e);
    return adoptResult(json);
}

/// Every variable of collection `col` resolved in each of its modes (`Editor.variableTable`):
/// `{"<variable id>":[value | null, ...]}`; `col` empty: every variable in the default modes.
export fn pe_variable_table(s: *Session, col: [*]const u8, col_len: usize) i32 {
    const json = s.edit.variableTable(gpa, col[0..col_len]) catch |e| return fail(e);
    return adoptResult(json);
}

/// The mode each collection is in at node `id`, and which node set it:
/// `[{"collection","mode","set"?}]`.
export fn pe_node_modes(s: *Session, id: [*]const u8, id_len: usize) i32 {
    const json = s.edit.modesAt(gpa, id[0..id_len]) catch |e| return fail(e);
    return adoptResult(json);
}

/// `document.json` to save: the document kept page by page (one in a single file is split
/// now), each loaded page's frames as they are.
export fn pe_save_document(s: *Session) i32 {
    const json = s.edit.documentJson(gpa) catch |e| return fail(e);
    return adoptResult(json);
}

/// Page `page`'s file to save: what goes in `pages/<id>.json` (`pe_page_file` names it
/// once `pe_save_document` has split a document in one file).
export fn pe_save_page(s: *Session, page: u32) i32 {
    const json = s.edit.pageJson(gpa, page) catch |e| return fail(e);
    return adoptResult(json);
}

/// The pages with changes not saved, as a JSON array of indexes.
export fn pe_dirty_pages(s: *Session) i32 {
    var list: std.ArrayList(u32) = .empty;
    defer list.deinit(gpa);
    for (s.edit.dirty.items, 0..) |d, i| if (d) list.append(gpa, @intCast(i)) catch |e| return fail(e);
    return setJson(list.items);
}

/// The pages were saved.
export fn pe_saved(s: *Session) void {
    s.edit.saved();
}

// ---------------------------------------------------------------- the canvas's tools
// Moving, resizing, drawing and text editing on the canvas (`edit/canvas.zig`,
// `edit/text_edit.zig`); the edits go through `pe_edit_apply`.

/// Nodes (a JSON array of ids) with their places on the page (`edit/canvas.zig` nodesJson).
export fn pe_canvas_nodes(s: *Session, ptr: [*]const u8, len: usize) i32 {
    const json = engine.edit_canvas.nodesJson(s, gpa, ptr[0..len]) catch |e| return fail(e);
    return adoptResult(json);
}

/// Node (or page) `id`'s children with their places on the page.
export fn pe_canvas_children(s: *Session, id: [*]const u8, id_len: usize) i32 {
    const json = engine.edit_canvas.childrenJson(s, gpa, id[0..id_len]) catch |e| return fail(e);
    return adoptResult(json);
}

/// The frame a drag dropping at (`x`, `y`) puts layers in, never one of `exclude`.
export fn pe_canvas_drop(s: *Session, page: u32, x: f32, y: f32, ptr: [*]const u8, len: usize) i32 {
    const json = engine.edit_canvas.dropJson(s, gpa, page, x, y, ptr[0..len]) catch |e| return fail(e);
    return adoptResult(json);
}

/// Node `id` with its subtree as Pubd JSON.
export fn pe_canvas_subtree(s: *Session, id: [*]const u8, id_len: usize) i32 {
    const json = engine.edit_canvas.subtreeJson(s, gpa, id[0..id_len]) catch |e| return fail(e);
    return adoptResult(json);
}

/// The changes that resize node `id` to `w` x `h` (`scale` 1: the scale tool).
export fn pe_canvas_resize(s: *Session, id: [*]const u8, id_len: usize, w: f32, h: f32, scale: u32) i32 {
    const json = engine.edit_canvas.resizePlan(s, gpa, id[0..id_len], w, h, scale != 0) catch |e| return fail(e);
    return adoptResult(json);
}

/// Text node `id`'s lines and characters as laid out, for the caret.
export fn pe_text_layout(s: *Session, id: [*]const u8, id_len: usize) i32 {
    const json = engine.edit_text.layoutJson(s, gpa, id[0..id_len]) catch |e| return fail(e);
    return adoptResult(json);
}
