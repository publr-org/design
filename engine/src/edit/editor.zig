//! The editing core: changes to an open document, undo and redo, the relayout and the
//! invalidation they need, and instances that follow their main components
//! (`.agents/specs/publr-design-editing.md`).
//!
//! Every edit is a `Change` (change.zig). The editor applies it, then whatever it sets
//! off: overrides recorded on the instance it was made in, the same change in every
//! instance of the main component it was made in (but for what an instance overrides),
//! auto layout where sizes follow content. All of it is recorded in the open step with
//! its inverse, so undo and redo replay the record and run nothing again.
//!
//! Each applied change bumps revisions (`m.Node.rev`, `tree_rev`), names the node
//! pointers whose kept data is stale (`forgotten`, read by the GPU scene), the page
//! rects it painted before and after (`damage`, for CPU tiles), and goes out in order
//! (`takeOut`) so other engines holding the document (the render workers) replay it.

const std = @import("std");
const m = @import("../pubd/model.zig");
const geom = @import("../raster/geom.zig");
const read = @import("../pubd/read.zig");
const write = @import("../pubd/write.zig");
const render = @import("../render/render.zig");
const lay = @import("../layout/layout.zig");
const pages_mod = @import("../import/pages.zig");
const jv = @import("../jv.zig");
const props = @import("props.zig");
const pubd_vars = @import("../pubd/vars.zig");
const change_mod = @import("change.zig");
const Session = @import("../session.zig").Session;

pub const Change = change_mod.Change;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const Stringify = std.json.Stringify;
const Affine = geom.Affine;

/// How a change is applied.
const Mode = enum {
    /// Made by the person: recorded, sets things off.
    user,
    /// Set off by another change (propagation, overrides, layout): recorded as such.
    derived,
    /// Undo and redo: applied as recorded, nothing set off.
    replay,
    /// Bringing instances up to their mains outside any step (a page opened, an undo
    /// another page did not take part in): sets things off, not recorded.
    sync,
};

const Entry = struct {
    fwd: Change,
    inv: Change,
    /// Set off by another change rather than made by the person.
    derived: bool,
};

/// One undo step.
const Step = struct {
    arena: std.heap.ArenaAllocator,
    entries: std.ArrayList(Entry) = .empty,
    /// Coalescing looks back no further (just after the last structural change).
    fence: usize = 0,
    /// Set entries after the fence by node and keys: a later set of the same keys of
    /// the same node replaces their new values.
    sets: std.StringHashMapUnmanaged(usize) = .empty,
    sel_before: []const u8 = "[]",
    sel_after: []const u8 = "[]",
    /// The page of its first change (-1: the document).
    page: i32 = -1,
    /// `page` comes from a change the person made (what it set off may be elsewhere:
    /// overrides worked out on instances on other pages).
    page_own: bool = false,
    /// The pages loaded when it was made (ids): their instances took its propagation.
    covered: std.ArrayList([]const u8) = .empty,
    /// Main components it changed (ids): pages not covered sync theirs on undo and redo.
    mains: std.ArrayList([]const u8) = .empty,
    /// Layers a drag holds in their auto layouts (`Editor.hold`).
    held: []const []const u8 = &.{},

    fn bytes(s: *const Step) usize {
        var n: usize = @sizeOf(Step);
        for (s.entries.items) |e| n += e.fwd.bytes() + e.inv.bytes() + @sizeOf(Entry);
        return n;
    }
};

const Restore = struct {
    at: usize,
    json: []const u8,
};

/// A rect of a page that a change painted (page units).
pub const Damage = struct {
    page: u32,
    rect: geom.Rect,
};

/// A change as it went out, for engines that replay it.
const Out = struct {
    page: i32,
    /// The page's `edits` with this change.
    edits: u64 = 0,
    json: []const u8,
};

pub const Editor = struct {
    gpa: Allocator,
    sess: *Session,
    /// Nodes and values edits make; lives as long as the document.
    arena: std.heap.ArenaAllocator,
    /// Each node's parent id ("" for pages), for the loaded pages; built on first use.
    parents: std.StringHashMapUnmanaged([]const u8) = .empty,
    indexed: bool = false,
    /// Real instances by main component id, for the loaded pages; rebuilt when needed.
    instances: std.StringHashMapUnmanaged(std.ArrayList([]const u8)) = .empty,
    instances_ok: bool = false,
    /// Nodes painting with a pattern and the pattern's source node (ids), for the loaded
    /// pages; rebuilt with `instances`.
    pattern_users: std.ArrayList([2][]const u8) = .empty,
    /// Each main component as it was before this session first changed it (Pubd JSON):
    /// instances whose overrides were never recorded are compared with it.
    originals: std.StringHashMapUnmanaged([]const u8) = .empty,
    /// The revision the current call stamps on what it changes.
    stamp: u32 = 0,
    /// New node ids are `<id_session>:<n>`.
    id_session: u32 = 1_000_000,
    id_next: u32 = 1,
    undo_stack: std.ArrayList(*Step) = .empty,
    redo_stack: std.ArrayList(*Step) = .empty,
    open: ?*Step = null,
    depth: u32 = 0,
    /// The selection as the host gave it (a JSON array of ids).
    selection: []u8 = &.{},
    /// Per page: changed since it was read or saved.
    dirty: std.ArrayList(bool) = .empty,
    /// Per page: the undo history changes it, so it stays loaded (undo finds its nodes).
    kept: std.ArrayList(bool) = .empty,
    /// What the calls since `takeOut` applied, in order.
    out: std.ArrayList(Out) = .empty,
    out_arena: std.heap.ArenaAllocator,
    damage: std.ArrayList(Damage) = .empty,
    /// The page list changed (a page added, removed, renamed or its frames changed).
    pages_changed: bool = false,
    /// Node pointers whose kept data (paths, text layouts, polylines) is stale: changed,
    /// moved, or gone. The GPU scene drops what it keeps of them at its next frame.
    forgotten: std.ArrayList(usize) = .empty,
    /// Nodes whose subtree changed (their pixels): kept data about the subtree is stale.
    forgotten_trees: std.ArrayList(usize) = .empty,
    /// Nodes to lay out once the current call's changes are in.
    layout_dirty: std.ArrayList([]const u8) = .empty,
    /// Instances to fit to their main's geometry before layout (`refit`).
    refits: std.ArrayList([]const u8) = .empty,
    /// Memory for the current call; reset at its end.
    call: std.heap.ArenaAllocator,
    /// Layout runs with these fonts.
    layout_options: lay.Options = .{},
    /// Where the current call's entries start in the open step, and its fence then.
    mark: usize = 0,
    mark_fence: usize = 0,
    /// Entries from before the current call that it changed again: their new values then.
    restores: std.ArrayList(Restore) = .empty,
    /// Nodes whose bound fields to resolve once the call's changes are in (ids), and
    /// nodes whose whole subtree is to be (a mode set on it, or it moved or arrived).
    var_nodes: std.ArrayList([]const u8) = .empty,
    var_trees: std.ArrayList([]const u8) = .empty,
    /// Variables the call changed (ids); `vars_all`: every variable may have (a
    /// collection changed, or an undo).
    vars_changed: std.ArrayList([]const u8) = .empty,
    vars_all: bool = false,
    /// The resolution pass is applying what it found: that marks nothing more.
    resolving: bool = false,
    /// What the resolution pass applies now changed only paints: nothing to lay out.
    paint_only: bool = false,
    /// While overrides are worked out: the variables, to resolve the main's fields as
    /// they would be where the instance is.
    infer_ix: ?*const pubd_vars.Index = null,

    pub fn init(gpa: Allocator, sess: *Session) Editor {
        return .{
            .gpa = gpa,
            .sess = sess,
            .arena = .init(gpa),
            .out_arena = .init(gpa),
            .call = .init(gpa),
        };
    }

    pub fn deinit(self: *Editor) void {
        self.reset();
        self.parents.deinit(self.gpa);
        self.instances.deinit(self.gpa);
        self.pattern_users.deinit(self.gpa);
        self.originals.deinit(self.gpa);
        self.undo_stack.deinit(self.gpa);
        self.redo_stack.deinit(self.gpa);
        self.dirty.deinit(self.gpa);
        self.kept.deinit(self.gpa);
        self.out.deinit(self.gpa);
        self.damage.deinit(self.gpa);
        self.forgotten.deinit(self.gpa);
        self.forgotten_trees.deinit(self.gpa);
        self.layout_dirty.deinit(self.gpa);
        self.refits.deinit(self.gpa);
        self.restores.deinit(self.gpa);
        self.var_nodes.deinit(self.gpa);
        self.var_trees.deinit(self.gpa);
        self.vars_changed.deinit(self.gpa);
        self.arena.deinit();
        self.out_arena.deinit();
        self.call.deinit();
    }

    /// Forgets the document: history, indexes, everything edits made.
    pub fn reset(self: *Editor) void {
        for (self.undo_stack.items) |s| self.freeStep(s);
        for (self.redo_stack.items) |s| self.freeStep(s);
        if (self.open) |s| self.freeStep(s);
        self.open = null;
        self.layout_options.held = &.{};
        self.depth = 0;
        self.undo_stack.clearRetainingCapacity();
        self.redo_stack.clearRetainingCapacity();
        self.parents.clearRetainingCapacity();
        self.indexed = false;
        self.dropInstances();
        self.originals.clearRetainingCapacity();
        self.dirty.clearRetainingCapacity();
        self.kept.clearRetainingCapacity();
        self.out.clearRetainingCapacity();
        _ = self.out_arena.reset(.free_all);
        self.damage.clearRetainingCapacity();
        self.forgotten.clearRetainingCapacity();
        self.forgotten_trees.clearRetainingCapacity();
        self.layout_dirty.clearRetainingCapacity();
        self.refits.clearRetainingCapacity();
        self.clearVarMarks();
        self.gpa.free(self.selection);
        self.selection = &.{};
        _ = self.arena.reset(.free_all);
        self.pages_changed = false;
    }

    fn freeStep(self: *Editor, s: *Step) void {
        s.arena.deinit();
        self.gpa.destroy(s);
    }

    fn dropInstances(self: *Editor) void {
        var it = self.instances.valueIterator();
        while (it.next()) |l| l.deinit(self.gpa);
        self.instances.clearRetainingCapacity();
        self.pattern_users.clearRetainingCapacity();
        self.instances_ok = false;
    }

    // ------------------------------------------------------------------ the document

    fn doc(self: *Editor) !*m.Document {
        return if (self.sess.doc) |*d| d else error.NoDocument;
    }

    /// A document was opened: `pages` pages, none changed.
    pub fn opened(self: *Editor, page_count: usize) !void {
        self.reset();
        try self.dirty.appendNTimes(self.gpa, false, page_count);
        try self.kept.appendNTimes(self.gpa, false, page_count);
    }

    /// Page `i`'s nodes were read: they join the indexes, and instances of main
    /// components this session changed catch up with them.
    pub fn pageLoaded(self: *Editor, i: usize) !void {
        if (self.indexed) {
            const d = try self.doc();
            try self.indexTree(&d.pages[i], "");
        }
        self.dropInstances();
        if (self.originals.count() > 0) {
            const d = try self.doc();
            try self.syncPage(d.pages[i].id);
        }
    }

    /// Page `i`'s nodes are about to go: they leave the indexes.
    pub fn pageUnloading(self: *Editor, i: usize) void {
        if (self.indexed) {
            const d = self.doc() catch return;
            self.unindexTree(&d.pages[i]);
        }
        self.dropInstances();
    }

    /// Whether page `i` holds changes not saved.
    pub fn isDirty(self: *const Editor, i: usize) bool {
        return i < self.dirty.items.len and self.dirty.items[i];
    }

    /// Whether page `i` must stay loaded: changes not saved, or steps to undo or redo.
    pub fn mustStay(self: *const Editor, i: usize) bool {
        return self.isDirty(i) or (i < self.kept.items.len and self.kept.items[i]);
    }

    /// Builds the parent index now (it is built on first use).
    pub fn ensureIndexed(self: *Editor) !void {
        return self.ensureIndex();
    }

    fn ensureIndex(self: *Editor) !void {
        if (self.indexed) return;
        const d = try self.doc();
        for (d.pages, 0..) |*pg, i| {
            if (!self.sess.pageLoaded(i)) {
                try self.parents.put(self.gpa, pg.id, "");
                continue;
            }
            try self.indexTree(pg, "");
        }
        self.indexed = true;
    }

    fn indexTree(self: *Editor, n: *const m.Node, parent: []const u8) !void {
        try self.parents.put(self.gpa, n.id, parent);
        for (n.children) |*c| try self.indexTree(c, n.id);
    }

    fn unindexTree(self: *Editor, n: *const m.Node) void {
        for (n.children) |*c| self.unindexTree(c);
        _ = self.parents.remove(n.id);
    }

    pub fn node(self: *Editor, id: []const u8) ?*m.Node {
        const n = self.sess.renderer.nodes.get(id) orelse return null;
        return @constCast(n);
    }

    pub fn parentId(self: *Editor, id: []const u8) ?[]const u8 {
        return self.parents.get(id);
    }

    /// The node's parent, or null for a page (or a node not indexed).
    fn parentOf(self: *Editor, id: []const u8) ?*m.Node {
        const p = self.parents.get(id) orelse return null;
        if (p.len == 0) return null;
        return self.node(p);
    }

    /// The index of the page the node is on.
    pub fn pageOf(self: *Editor, id: []const u8) ?usize {
        var cur = id;
        var guard: u32 = 0;
        while (self.parents.get(cur)) |p| {
            if (p.len == 0) break;
            cur = p;
            guard += 1;
            if (guard > 100_000) return null;
        } else return null;
        const d = self.doc() catch return null;
        for (d.pages, 0..) |pg, i| if (std.mem.eql(u8, pg.id, cur)) return i;
        return null;
    }

    fn pageIndexById(self: *Editor, id: []const u8) ?usize {
        const d = self.doc() catch return null;
        for (d.pages, 0..) |pg, i| if (std.mem.eql(u8, pg.id, id)) return i;
        return null;
    }

    /// The nodes from the node's page down to it.
    fn pathTo(self: *Editor, a: Allocator, id: []const u8) ![]*m.Node {
        var list: std.ArrayList(*m.Node) = .empty;
        var cur = id;
        while (true) {
            try list.append(a, self.node(cur) orelse return error.NoSuchNode);
            const p = self.parents.get(cur) orelse return error.NoSuchNode;
            if (p.len == 0) break;
            cur = p;
        }
        std.mem.reverse(*m.Node, list.items);
        return list.items;
    }

    /// The node's space to its page's.
    fn pageCtm(self: *Editor, id: []const u8) Affine {
        var t: Affine = .identity;
        var cur = id;
        while (self.parents.get(cur)) |p| {
            if (p.len == 0) break;
            const n = self.node(cur) orelse break;
            t = n.transform.mul(t);
            cur = p;
        }
        return t;
    }

    /// Everything the node may paint on its page, grown by the reach of its ancestors'
    /// effects (a shadow their content casts moves with it).
    fn paintedRect(self: *Editor, n: *const m.Node) geom.Rect {
        const ctm = self.pageCtm(n.id);
        var r = render.cullBounds(n, ctm);
        var cur = n.id;
        while (self.parents.get(cur)) |p| {
            if (p.len == 0) break;
            const a = self.node(p) orelse break;
            if (contentEffects(a)) {
                const reach = render.effectExtent(a, self.pageCtm(a.id));
                if (reach > 0) r = r.outset(reach);
            }
            cur = p;
        }
        return r;
    }

    /// Whether a node's effects follow its content: shadows of a clipping container
    /// with an opaque solid fill are cast by its shape alone (`docs/gpu.md`).
    fn contentEffects(n: *const m.Node) bool {
        var any = false;
        for (n.effects) |e| {
            if (!e.visible) continue;
            if (e.kind != .drop_shadow and e.kind != .inner_shadow) return true;
            any = true;
        }
        if (!any) return false;
        if (!(n.clip and n.kind.isContainer())) return true;
        for (n.fills) |f| {
            if (f.visible and f.kind == .solid and f.opacity == 1 and f.color.a == 1) return false;
        }
        return true;
    }

    fn addDamage(self: *Editor, page: ?usize, r: geom.Rect) !void {
        const pg = page orelse return;
        if (r.isEmpty()) return;
        for (self.damage.items) |*d| {
            // Inside one already noted: nothing new.
            if (d.page == pg and d.rect.x0 <= r.x0 and d.rect.y0 <= r.y0 and d.rect.x1 >= r.x1 and d.rect.y1 >= r.y1) return;
        }
        try self.damage.append(self.gpa, .{
            .page = @intCast(pg),
            .rect = r,
        });
    }

    /// The node's own content changed: its revision and its ancestors' subtree
    /// revisions move on, and what is kept of it is stale.
    fn touch(self: *Editor, n: *m.Node) !void {
        n.shape_rev = self.stamp;
        try self.touchPaints(n);
    }

    /// Only the node's paints changed (fills, strokes, effects, opacity, blend): as
    /// `touch`, but its shape stays (its outline and its text's glyphs are kept).
    fn touchPaints(self: *Editor, n: *m.Node) !void {
        n.rev = self.stamp;
        try self.touchColours(n);
    }

    /// Only the colours of the node's paints changed (as a colour variable's new value
    /// gives them): its own revision stays, so what is drawn of it is painted again in
    /// place rather than written again; its subtree's revisions move on.
    fn touchColours(self: *Editor, n: *m.Node) !void {
        try self.forgotten.append(self.gpa, @intFromPtr(n));
        try self.touchTree(n.id);
    }

    /// The subtree of `id` and its ancestors changed.
    fn touchTree(self: *Editor, id: []const u8) !void {
        var cur = id;
        while (true) {
            const n = self.node(cur) orelse break;
            if (n.tree_rev == self.stamp) break;
            n.tree_rev = self.stamp;
            try self.forgotten_trees.append(self.gpa, @intFromPtr(n));
            const p = self.parents.get(cur) orelse break;
            if (p.len == 0) break;
            cur = p;
        }
    }

    /// A page or one of its top-level nodes (what the page list shows).
    fn isTopLevel(self: *Editor, id: []const u8) bool {
        const p = self.parents.get(id) orelse return false;
        if (p.len == 0) return true;
        const pp = self.parents.get(p) orelse return false;
        return pp.len == 0;
    }

    fn markDirty(self: *Editor, page: ?usize) void {
        const pg = page orelse return;
        if (pg < self.dirty.items.len) self.dirty.items[pg] = true;
    }

    // ------------------------------------------------------------------ ids

    /// The node's id with a leading `I` left off: its path inside a main component.
    pub fn local(id: []const u8) []const u8 {
        return if (id.len > 0 and id[0] == 'I') id[1..] else id;
    }

    /// The prefix the copies inside instance `id` take (`I<id>`, or the id itself when
    /// it is a copy already).
    fn prefixOf(a: Allocator, id: []const u8) ![]const u8 {
        if (id.len > 0 and id[0] == 'I') return id;
        return std.fmt.allocPrint(a, "I{s}", .{id});
    }

    /// The id of the copy at `path` inside instance `inst` ("" the instance itself).
    fn instId(a: Allocator, inst: []const u8, path: []const u8) ![]const u8 {
        if (path.len == 0) return inst;
        return std.fmt.allocPrint(a, "{s};{s}", .{ try prefixOf(a, inst), path });
    }

    /// The path of copy `id` inside instance `inst`, or null when it is not one of its.
    fn pathIn(a: Allocator, inst: []const u8, id: []const u8) !?[]const u8 {
        if (std.mem.eql(u8, inst, id)) return "";
        const pre = try prefixOf(a, inst);
        if (id.len > pre.len + 1 and std.mem.startsWith(u8, id, pre) and id[pre.len] == ';') return id[pre.len + 1 ..];
        return null;
    }

    /// A fresh node id.
    fn freshId(self: *Editor) ![]const u8 {
        while (true) {
            const id = try std.fmt.allocPrint(self.arena.allocator(), "{d}:{d}", .{ self.id_session, self.id_next });
            self.id_next += 1;
            if (self.sess.renderer.nodes.get(id) == null) return id;
        }
    }

    // ------------------------------------------------------------------ components

    /// Whether any ancestor of `id` is an instance (the node is a copy).
    fn insideInstance(self: *Editor, id: []const u8) bool {
        var cur = id;
        while (self.parents.get(cur)) |p| {
            if (p.len == 0) return false;
            const n = self.node(p) orelse return false;
            if (n.kind == .instance) return true;
            cur = p;
        }
        return false;
    }

    /// A real instance: an instance not inside another instance.
    fn isRealInstance(self: *Editor, n: *const m.Node) bool {
        return n.kind == .instance and !self.insideInstance(n.id);
    }

    const Owner = struct {
        inst: *m.Node,
        path: []const u8,
    };

    /// The outermost instance holding `n` (or `n` itself, a real instance) and `n`'s
    /// path inside it: where an override of `n` is recorded.
    fn ownerOf(self: *Editor, a: Allocator, n: *m.Node) !?Owner {
        var outer: ?*m.Node = if (n.kind == .instance) n else null;
        var cur = n.id;
        while (self.parents.get(cur)) |p| {
            if (p.len == 0) break;
            const pn = self.node(p) orelse break;
            if (pn.kind == .instance) outer = pn;
            cur = p;
        }
        const inst = outer orelse return null;
        const path = (try pathIn(a, inst.id, n.id)) orelse return null;
        return .{
            .inst = inst,
            .path = path,
        };
    }

    /// The main component `n` is in (or is): its nearest component ancestor that is not
    /// itself inside an instance.
    fn mainOf(self: *Editor, n: *m.Node) ?*m.Node {
        var cur: ?*m.Node = n;
        while (cur) |c| {
            if (c.kind == .component and !self.insideInstance(c.id)) return c;
            cur = self.parentOf(c.id);
        }
        return null;
    }

    /// `n`'s path inside main component `main`.
    fn mainPath(main: *const m.Node, n: *const m.Node) []const u8 {
        if (n == main) return "";
        return local(n.id);
    }

    /// The node at `path` inside main component `main`.
    fn mainNode(self: *Editor, a: Allocator, main: *m.Node, path: []const u8) !?*m.Node {
        if (path.len == 0) return main;
        if (std.mem.indexOfScalar(u8, path, ';') == null) {
            if (self.node(path)) |n| return n;
        }
        if (self.node(try std.fmt.allocPrint(a, "I{s}", .{path}))) |n| return n;
        return self.node(path);
    }

    fn rebuildInstances(self: *Editor) !void {
        if (self.instances_ok) return;
        self.dropInstances();
        const d = try self.doc();
        for (d.pages, 0..) |*pg, i| {
            if (!self.sess.pageLoaded(i)) continue;
            try self.collectInstances(pg);
        }
        self.instances_ok = true;
    }

    fn collectInstances(self: *Editor, n: *const m.Node) !void {
        for ([2][]const m.Paint{ n.fills, n.strokes }) |ps| for (ps) |p| {
            if (p.kind == .pattern and p.source.len > 0) try self.pattern_users.append(self.gpa, .{ n.id, p.source });
        };
        if (n.kind == .instance) {
            if (n.component) |c| {
                const got = try self.instances.getOrPut(self.gpa, c);
                if (!got.found_existing) got.value_ptr.* = .empty;
                try got.value_ptr.append(self.gpa, n.id);
            }
            // Copies inside are not real instances.
            return;
        }
        for (n.children) |*c| try self.collectInstances(c);
    }

    /// The real instances of main component `id` on the loaded pages (ids).
    fn instancesOf(self: *Editor, id: []const u8) ![]const []const u8 {
        try self.rebuildInstances();
        const l = self.instances.get(id) orelse return &.{};
        // A copy of the list: applying changes may rebuild the index.
        return self.call.allocator().dupe([]const u8, l.items);
    }

    fn overridesAt(inst: *const m.Node, path: []const u8) []const []const u8 {
        for (inst.overrides orelse return &.{}) |o| if (std.mem.eql(u8, o.path, path)) return o.keys;
        return &.{};
    }

    fn overrides(inst: *const m.Node, path: []const u8, key: []const u8) bool {
        for (overridesAt(inst, path)) |k| if (std.mem.eql(u8, k, key)) return true;
        return false;
    }

    /// Whether `path` inside `inst` lies under a nested instance the instance swapped
    /// for another component (what is there is not the main's).
    fn underSwap(inst: *const m.Node, path: []const u8) bool {
        var i: usize = 0;
        while (std.mem.indexOfScalarPos(u8, path, i, ';')) |at| {
            if (overrides(inst, path[0..at], "component")) return true;
            i = at + 1;
        }
        return false;
    }

    /// Keeps a copy of main component `main` as it is now, before this session first
    /// changes it, and works out the overrides of every instance that follows it (and,
    /// up the chain, of the instances of the mains those instances sit in).
    fn prepare(self: *Editor, n: *m.Node) !void {
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        defer seen.deinit(self.gpa);
        try self.prepareFrom(n, &seen);
    }

    fn prepareFrom(self: *Editor, n: *m.Node, seen: *std.StringHashMapUnmanaged(void)) anyerror!void {
        if (try self.ownerOf(self.call.allocator(), n)) |o| try self.ensureOverrides(o.inst);
        const main = self.mainOf(n) orelse return;
        if (seen.contains(main.id)) return;
        try seen.put(self.gpa, main.id, {});
        try self.noteMain(main.id);
        if (!self.originals.contains(main.id)) {
            const json = try write.nodeJson(self.arena.allocator(), main, .{});
            try self.originals.put(self.gpa, main.id, json);
        }
        for (try self.instancesOf(main.id)) |xid| {
            const x = self.node(xid) orelse continue;
            try self.ensureOverrides(x);
            try self.prepareFrom(x, seen);
        }
    }

    /// Records instance `x`'s overrides if the file did not, by comparing it with its
    /// main component as it was before this session changed it.
    fn ensureOverrides(self: *Editor, x: *m.Node) !void {
        if (x.overrides != null or x.kind != .instance) return;
        const cid = x.component orelse return;
        const a = self.call.allocator();
        var keep: std.heap.ArenaAllocator = .init(self.gpa);
        defer keep.deinit();
        const main: *const m.Node = if (self.originals.get(cid)) |json|
            &(try read.nodeFromJson(self.gpa, keep.allocator(), json, .{}))
        else
            self.node(cid) orelse return;
        var list: std.ArrayList(Ov) = .empty;
        // A field bound to a variable may differ from the main's only because the
        // instance sits in another mode: compared as the main's would resolve there.
        const d = try self.doc();
        var ix: ?pubd_vars.Index = if (d.variables.len > 0) try pubd_vars.Index.init(self.gpa, d) else null;
        defer if (ix) |*i| i.deinit(self.gpa);
        self.infer_ix = if (ix) |*i| i else null;
        defer self.infer_ix = null;
        try self.infer(a, x, x, main, &list, keep.allocator());
        const json = try overridesJson(a, list.items);
        const patch = try std.fmt.allocPrint(a, "{{\"overrides\":{s}}}", .{json});
        try self.prim(.{
            .op = .set,
            .node = x.id,
            .json = patch,
        }, .derived);
    }

    const Ov = struct {
        path: []const u8,
        keys: std.ArrayList([]const u8),
    };

    /// Keys compared when overrides are worked out (what an instance may override and a
    /// file keeps as the node's own; geometry follows layout, caches are derived).
    fn comparable(k: *const props.Key, root: bool) bool {
        if (!k.override) return false;
        if (std.mem.eql(u8, k.name, "transform")) return false;
        if (std.mem.eql(u8, k.name, "size")) return root;
        // An instance is often named after its set rather than its variant.
        if (std.mem.eql(u8, k.name, "name")) return !root;
        if (std.mem.eql(u8, k.name, "props")) return false;
        return true;
    }

    fn infer(self: *Editor, a: Allocator, x: *const m.Node, xn: *const m.Node, rn_in: *const m.Node, out: *std.ArrayList(Ov), keep: Allocator) !void {
        const path = (try pathIn(a, x.id, xn.id)) orelse return;
        var rn = rn_in;
        if (self.infer_ix) |ix| if (pubd_vars.hasBindings(rn_in)) {
            const rc = try a.create(m.Node);
            rc.* = rn_in.*;
            const xpath = try self.pathTo(a, xn.id);
            const modes = pubd_vars.modesAlong(a, xpath) catch &.{};
            _ = try pubd_vars.applyNodeAt(ix, a, a, rc, modes, pubd_vars.scaleAlong(xpath));
            rn = rc;
        };
        const root = xn == x;
        var ov: Ov = .{
            .path = path,
            .keys = .empty,
        };
        var names: std.ArrayList([]const u8) = .empty;
        for (&props.keys) |*k| {
            if (!comparable(k, root)) continue;
            if (k.text and (xn.kind != .text or rn.kind != .text)) continue;
            if (std.mem.eql(u8, k.name, "component") and (root or xn.kind != .instance)) continue;
            try names.append(a, k.name);
        }
        const xv = try props.values(a, xn, names.items);
        const rv = try props.values(a, rn, names.items);
        const xo = (try read.parseValue(a, xv)).object;
        const ro = (try read.parseValue(a, rv)).object;
        for (names.items) |name| {
            var p = xo.get(name).?;
            var q = ro.get(name).?;
            if (std.mem.eql(u8, name, "stroke")) {
                // The resolved outline follows the size.
                if (p == .object) _ = p.object.orderedRemove("outline");
                if (q == .object) _ = q.object.orderedRemove("outline");
            }
            const ps = try Stringify.valueAlloc(a, p, .{});
            const qs = try Stringify.valueAlloc(a, q, .{});
            if (!std.mem.eql(u8, ps, qs)) try ov.keys.append(a, name);
        }
        if (ov.keys.items.len > 0) try out.append(a, ov);
        // A nested instance swapped for another component: what is under it is that
        // component's.
        var ref = rn;
        if (!root and xn.kind == .instance and rn.kind == .instance and xn.component != null) {
            if (!std.mem.eql(u8, xn.component.?, rn.component orelse "")) {
                const sw = self.originalOrNode(keep, xn.component.?) orelse return;
                ref = sw;
            }
        }
        if (xn.children.len != ref.children.len) return;
        for (xn.children, ref.children) |*xc, *rc| {
            if (xc.kind != rc.kind) continue;
            try self.infer(a, x, xc, rc, out, keep);
        }
    }

    fn originalOrNode(self: *Editor, keep: Allocator, id: []const u8) ?*const m.Node {
        if (self.originals.get(id)) |json| {
            const n = keep.create(m.Node) catch return null;
            n.* = read.nodeFromJson(self.gpa, keep, json, .{}) catch return null;
            return n;
        }
        return self.node(id);
    }

    fn overridesJson(a: Allocator, list: []const Ov) ![]const u8 {
        var out: std.Io.Writer.Allocating = .init(a);
        var s: Stringify = .{
            .writer = &out.writer,
        };
        try s.beginObject();
        for (list) |o| {
            try s.objectField(o.path);
            try s.write(o.keys.items);
        }
        try s.endObject();
        return out.written();
    }

    /// The instance's overrides with `keys` added at `path` (or removed, `add` false), as
    /// the JSON of the `overrides` key.
    fn editOverrides(a: Allocator, inst: *const m.Node, path: []const u8, keys: []const []const u8, add: bool) ![]const u8 {
        var list: std.ArrayList(Ov) = .empty;
        var found = false;
        for (inst.overrides orelse &.{}) |o| {
            var ov: Ov = .{
                .path = o.path,
                .keys = .empty,
            };
            try ov.keys.appendSlice(a, o.keys);
            if (std.mem.eql(u8, o.path, path)) {
                found = true;
                for (keys) |k| {
                    const at = for (ov.keys.items, 0..) |x, i| {
                        if (std.mem.eql(u8, x, k)) break i;
                    } else null;
                    if (add and at == null) try ov.keys.append(a, k);
                    if (!add) if (at) |i| {
                        _ = ov.keys.orderedRemove(i);
                    };
                }
            }
            if (ov.keys.items.len > 0) try list.append(a, ov);
        }
        if (add and !found) {
            var ov: Ov = .{
                .path = path,
                .keys = .empty,
            };
            try ov.keys.appendSlice(a, keys);
            if (ov.keys.items.len > 0) try list.append(a, ov);
        }
        return overridesJson(a, list.items);
    }

    // ------------------------------------------------------------------ steps

    /// Starts a step: changes until the matching `commit` undo as one. Steps nest; the
    /// outermost one counts.
    pub fn begin(self: *Editor) !void {
        self.depth += 1;
        if (self.open != null) return;
        const s = try self.gpa.create(Step);
        s.* = .{
            .arena = .init(self.gpa),
        };
        s.sel_before = try s.arena.allocator().dupe(u8, self.selectionJson());
        self.open = s;
    }

    /// Ends a step. A step that changed nothing is dropped; one that did drops the steps
    /// undone before it.
    pub fn commit(self: *Editor) !void {
        if (self.depth == 0) return;
        self.depth -= 1;
        if (self.depth > 0) return;
        const s = self.open orelse return;
        if (s.held.len > 0) try self.hold(&.{});
        self.open = null;
        if (s.entries.items.len == 0) return self.freeStep(s);
        const a = s.arena.allocator();
        s.sel_after = try a.dupe(u8, self.selectionJson());
        const d = try self.doc();
        for (d.pages, 0..) |pg, i| if (self.sess.pageLoaded(i)) try s.covered.append(a, try a.dupe(u8, pg.id));
        for (self.redo_stack.items) |r| self.freeStep(r);
        self.redo_stack.clearRetainingCapacity();
        try self.undo_stack.append(self.gpa, s);
    }

    /// Ends the open step by undoing what it did (Escape during a drag).
    pub fn cancel(self: *Editor) !void {
        const s = self.open orelse return;
        self.layout_options.held = &.{};
        self.open = null;
        self.depth = 0;
        self.beginCall();
        defer self.endCall();
        var i = s.entries.items.len;
        while (i > 0) {
            i -= 1;
            try self.prim(s.entries.items[i].inv, .replay);
        }
        try self.syncVars(s);
        self.freeStep(s);
    }

    /// Holds layers `ids` in their auto layouts for the open step (a drag): each keeps
    /// its place in the flow while the drag moves it. Layers no longer held go back to
    /// their places; the step's end lets go of all.
    pub fn hold(self: *Editor, ids: []const []const u8) !void {
        const s = self.open orelse return error.NoOpenStep;
        self.beginCall();
        defer self.endCall();
        for (s.held) |id| {
            for (ids) |k| {
                if (std.mem.eql(u8, k, id)) break;
            } else if (self.parentOf(id)) |p| if (p.kind != .page) try self.markLayout(p.id);
        }
        const a = s.arena.allocator();
        const copy = try a.alloc([]const u8, ids.len);
        for (ids, copy) |id, *c| c.* = try a.dupe(u8, id);
        s.held = copy;
        self.layout_options.held = copy;
        try self.flush();
    }

    fn selectionJson(self: *const Editor) []const u8 {
        return if (self.selection.len > 0) self.selection else "[]";
    }

    /// The selection now (a JSON array of ids): a step keeps it to put back.
    pub fn setSelection(self: *Editor, json: []const u8) !void {
        const copy = try self.gpa.dupe(u8, json);
        self.gpa.free(self.selection);
        self.selection = copy;
    }

    pub fn canUndo(self: *const Editor) bool {
        return self.undo_stack.items.len > 0;
    }

    pub fn canRedo(self: *const Editor) bool {
        return self.redo_stack.items.len > 0;
    }

    /// What one step put back.
    pub const Restored = struct {
        selection: []const u8,
        page: i32,
    };

    /// Undoes the last step: the selection before it, and its page.
    pub fn undo(self: *Editor) !?Restored {
        if (self.open != null) try self.commitAll();
        const s = self.undo_stack.pop() orelse return null;
        self.beginCall();
        defer self.endCall();
        var i = s.entries.items.len;
        while (i > 0) {
            i -= 1;
            try self.prim(s.entries.items[i].inv, .replay);
        }
        try self.syncUncovered(s);
        try self.syncVars(s);
        try self.redo_stack.append(self.gpa, s);
        try self.setSelection(s.sel_before);
        return .{
            .selection = s.sel_before,
            .page = s.page,
        };
    }

    /// Redoes the last step undone: the selection after it, and its page.
    pub fn redo(self: *Editor) !?Restored {
        if (self.open != null) try self.commitAll();
        const s = self.redo_stack.pop() orelse return null;
        self.beginCall();
        defer self.endCall();
        for (s.entries.items) |e| try self.prim(e.fwd, .replay);
        try self.syncUncovered(s);
        try self.syncVars(s);
        try self.undo_stack.append(self.gpa, s);
        try self.setSelection(s.sel_after);
        return .{
            .selection = s.sel_after,
            .page = s.page,
        };
    }

    fn commitAll(self: *Editor) !void {
        self.depth = 1;
        try self.commit();
    }

    /// Bytes the undo and redo history holds.
    pub fn historyBytes(self: *const Editor) usize {
        var n: usize = 0;
        for (self.undo_stack.items) |s| n += s.bytes();
        for (self.redo_stack.items) |s| n += s.bytes();
        if (self.open) |s| n += s.bytes();
        return n;
    }

    fn beginCall(self: *Editor) void {
        self.stamp +%= 1;
        if (self.stamp == 0) self.stamp = 1;
    }

    fn endCall(self: *Editor) void {
        self.touchPatternUsers() catch {};
        _ = self.call.reset(.retain_capacity);
    }

    /// A node that paints another as a pattern changed when that node did.
    fn touchPatternUsers(self: *Editor) !void {
        if (self.forgotten_trees.items.len == 0 or !self.indexed) return;
        try self.rebuildInstances();
        for (self.pattern_users.items) |pu| {
            const src = self.node(pu[1]) orelse continue;
            if (src.tree_rev != self.stamp) continue;
            const user = self.node(pu[0]) orelse continue;
            if (user.tree_rev == self.stamp) continue;
            try self.touchTree(user.id);
            try self.addDamage(self.pageOf(user.id), self.paintedRect(user));
        }
    }

    /// Records an applied change in the open step (a step of its own when none is open).
    fn record(self: *Editor, fwd: Change, inv: Change, derived: bool) !void {
        const s = self.open orelse return;
        if (self.pageForChange(fwd)) |p| if (p < self.kept.items.len) {
            self.kept.items[p] = true;
        };
        const a = s.arena.allocator();
        if (s.entries.items.len == 0 or (!derived and !s.page_own)) {
            s.page = if (self.pageForChange(fwd)) |p| @intCast(p) else -1;
            s.page_own = !derived;
        }
        if (fwd.op == .set) {
            const sig = try setSignature(self.call.allocator(), fwd);
            if (s.sets.get(sig)) |at| {
                // The same keys of the same node again: one entry, the first old values
                // and the last new ones.
                if (at < self.mark) {
                    var seen = false;
                    for (self.restores.items) |r| seen = seen or r.at == at;
                    if (!seen) try self.restores.append(self.gpa, .{
                        .at = at,
                        .json = s.entries.items[at].fwd.json,
                    });
                }
                s.entries.items[at].fwd.json = try a.dupe(u8, fwd.json);
                return;
            }
            try s.entries.append(a, .{
                .fwd = try fwd.dupe(a),
                .inv = try inv.dupe(a),
                .derived = derived,
            });
            try s.sets.put(a, try a.dupe(u8, sig), s.entries.items.len - 1);
            return;
        }
        try s.entries.append(a, .{
            .fwd = try fwd.dupe(a),
            .inv = try inv.dupe(a),
            .derived = derived,
        });
        s.fence = s.entries.items.len;
        s.sets.clearRetainingCapacity();
    }

    fn setSignature(a: Allocator, c: Change) ![]const u8 {
        const v = try read.parseValue(a, c.json);
        var out: std.Io.Writer.Allocating = .init(a);
        try out.writer.writeAll(c.node);
        var it = v.object.iterator();
        while (it.next()) |e| {
            try out.writer.writeByte(0);
            try out.writer.writeAll(e.key_ptr.*);
        }
        return out.written();
    }

    /// The open step changed main component `id`.
    fn noteMain(self: *Editor, id: []const u8) !void {
        const s = self.open orelse return;
        for (s.mains.items) |x| if (std.mem.eql(u8, x, id)) return;
        try s.mains.append(s.arena.allocator(), try s.arena.allocator().dupe(u8, id));
    }

    fn pageForChange(self: *Editor, c: Change) ?usize {
        return switch (c.op) {
            .set, .delete, .move => self.pageOf(c.node),
            .insert => if (c.parent.len == 0) null else self.pageOf(c.parent),
            .style, .variable, .collection => null,
        };
    }

    // ------------------------------------------------------------------ applying

    /// Applies changes from their JSON form: one change object or an array of them,
    /// in one step (the open one, or a step of their own). Besides the five changes:
    ///   {"op":"reset","node":id,"keys":[...]}   an instance's overrides back to the main
    ///   {"op":"prop","node":id,"prop":id,"value":v}   a component property (null: reset)
    ///   {"op":"detach","node":id}                an instance becomes a frame
    /// An insert of an `instance` with no children takes its main's content; a set of an
    /// instance's `component` swaps it.
    pub fn apply(self: *Editor, json: []const u8) !void {
        try self.ensureIndex();
        self.beginCall();
        defer self.endCall();
        const own = self.open == null;
        if (own) try self.begin();
        defer if (own) self.commit() catch {};
        const st = self.open.?;
        self.mark = st.entries.items.len;
        self.mark_fence = st.fence;
        self.restores.clearRetainingCapacity();
        const a = self.call.allocator();
        self.applyAll(a, json) catch |e| {
            // A change that fails takes back what the call did before it.
            self.rollback() catch {};
            return e;
        };
    }

    fn applyAll(self: *Editor, a: Allocator, json: []const u8) !void {
        const v = try read.parseValue(a, json);
        if (v == .array) {
            for (v.array.items) |c| try self.applyValue(c);
        } else try self.applyValue(v);
        try self.flush();
    }

    /// Takes back what the current call recorded in the open step.
    fn rollback(self: *Editor) !void {
        const s = self.open orelse return;
        self.layout_dirty.clearRetainingCapacity();
        self.refits.clearRetainingCapacity();
        self.clearVarMarks();
        var i = s.entries.items.len;
        while (i > self.mark) {
            i -= 1;
            try self.prim(s.entries.items[i].inv, .replay);
        }
        // Entries from before the call that it changed again.
        var k = self.restores.items.len;
        while (k > 0) {
            k -= 1;
            const r = self.restores.items[k];
            s.entries.items[r.at].fwd.json = r.json;
            try self.prim(s.entries.items[r.at].fwd, .replay);
        }
        s.entries.shrinkRetainingCapacity(self.mark);
        s.fence = self.mark_fence;
        var it = s.sets.iterator();
        var drop: std.ArrayList([]const u8) = .empty;
        while (it.next()) |e| if (e.value_ptr.* >= self.mark) try drop.append(self.call.allocator(), e.key_ptr.*);
        for (drop.items) |key| _ = s.sets.remove(key);
    }

    fn applyValue(self: *Editor, v: Value) !void {
        const a = self.call.allocator();
        const op = jv.str(v, "op") orelse return error.BadChange;
        if (std.mem.eql(u8, op, "reset")) return self.resetOverrides(jv.str(v, "node") orelse return error.BadChange, if (jv.get(v, "keys")) |k| (if (k == .array) k.array.items else null) else null);
        if (std.mem.eql(u8, op, "prop")) return self.setProperty(jv.str(v, "node") orelse return error.BadChange, jv.str(v, "prop") orelse return error.BadChange, jv.get(v, "value") orelse .null);
        if (std.mem.eql(u8, op, "detach")) return self.detach(jv.str(v, "node") orelse return error.BadChange);
        const c = try Change.fromValue(a, v);
        try self.userChange(c);
    }

    /// A change the person made: checked, completed, applied, and what it sets off.
    fn userChange(self: *Editor, c0: Change) !void {
        const a = self.call.allocator();
        var c = c0;
        switch (c.op) {
            .set => {
                const n = self.node(c.node) orelse if (c.node.len == 0) return self.prim(c, .user) else return error.NoSuchNode;
                c.json = try self.completeSet(a, n, c.json);
                const swap = n.kind == .instance and try hasKey(a, c.json, "component");
                try self.prepare(n);
                try self.prim(c, .user);
                try self.recordOverride(n, c.json);
                try self.propagate(c);
                if (swap) try self.rebuild(c.node, true, .derived);
            },
            .insert => {
                if (c.parent.len > 0) {
                    const p = self.node(c.parent) orelse return error.NoSuchParent;
                    if (p.kind == .instance or self.insideInstance(p.id)) return error.InsideInstance;
                    try self.prepare(p);
                }
                c.json = try self.completeInsert(a, c.json);
                c.node = jv.str(try read.parseValue(a, c.json), "id").?;
                try self.prim(c, .user);
                try self.propagate(c);
            },
            .delete => {
                const n = self.node(c.node) orelse return error.NoSuchNode;
                if (self.insideInstance(n.id)) return error.InsideInstance;
                try self.prepare(n);
                const ts = try self.targets(c);
                try self.prim(c, .user);
                try self.propagateTargets(c, ts);
            },
            .move => {
                const n = self.node(c.node) orelse return error.NoSuchNode;
                if (self.insideInstance(n.id)) return error.InsideInstance;
                if (c.parent.len > 0) {
                    const p = self.node(c.parent) orelse return error.NoSuchParent;
                    if (p.kind == .instance or self.insideInstance(p.id)) return error.InsideInstance;
                    try self.prepare(p);
                }
                try self.prepare(n);
                const ts = try self.targets(c);
                try self.prim(c, .user);
                try self.propagateTargets(c, ts);
            },
            .style, .variable, .collection => try self.prim(c, .user),
        }
    }

    fn hasKey(a: Allocator, json: []const u8, key: []const u8) !bool {
        const v = try read.parseValue(a, json);
        return v == .object and v.object.get(key) != null;
    }

    /// A set made whole: a change to a text's content drops the layout its source
    /// stored, and new characters keep the runs inside them.
    fn completeSet(self: *Editor, a: Allocator, n: *const m.Node, json: []const u8) ![]const u8 {
        var v = try read.parseValue(a, json);
        if (v != .object) return error.BadChange;
        try self.detachStale(a, n, &v);
        if (v.object.get("type")) |t| {
            const to = if (t == .string) t.string else return error.CannotChangeType;
            if (!n.kind.isContainer()) return error.CannotChangeType;
            var buf: [40]u8 = undefined;
            for (to, 0..) |ch, i| {
                if (i >= buf.len) return error.CannotChangeType;
                buf[i] = if (ch == '-') '_' else ch;
            }
            const k = std.meta.stringToEnum(m.Kind, buf[0..@min(to.len, buf.len)]) orelse return error.CannotChangeType;
            if (!k.isContainer()) return error.CannotChangeType;
        }
        const t = n.text orelse return Stringify.valueAlloc(a, v, .{});
        var content = false;
        for (props.text_content) |k| content = content or v.object.get(k) != null;
        if (!content) return Stringify.valueAlloc(a, v, .{});
        if (t.glyphs.len > 0 and v.object.get("glyphs") == null) try v.object.put(a, "glyphs", .null);
        if (t.glyph_rects.len > 0 and v.object.get("glyphRects") == null) try v.object.put(a, "glyphRects", .null);
        if (v.object.get("text")) |nt| if (nt == .string and v.object.get("runs") == null and t.runs.len > 0) {
            // Runs past the new end are cut there.
            const len: u32 = @intCast(utf16Len(nt.string));
            var probe = n.*;
            var tt = t;
            var runs: std.ArrayList(m.Run) = .empty;
            var changed = false;
            for (t.runs) |r| {
                if (r.from >= len) {
                    changed = true;
                    continue;
                }
                var r2 = r;
                if (r2.to > len) {
                    r2.to = len;
                    changed = true;
                }
                try runs.append(a, r2);
            }
            if (changed) {
                tt.runs = runs.items;
                probe.text = tt;
                const rv = try props.values(a, &probe, &.{"runs"});
                const parsed = try read.parseValue(a, rv);
                try v.object.put(a, "runs", parsed.object.get("runs").?);
            }
        };
        return Stringify.valueAlloc(a, v, .{});
    }

    fn utf16Len(s: []const u8) usize {
        var n: usize = 0;
        var it = std.unicode.Utf8View.initUnchecked(s).iterator();
        while (it.nextCodepoint()) |cp| n += if (cp >= 0x10000) 2 else 1;
        return n;
    }

    /// An insert made whole: ids that are missing or taken get fresh ones (the copies
    /// inside an instance follow theirs), and an instance with no children takes its
    /// main's content.
    fn completeInsert(self: *Editor, a: Allocator, json: []const u8) ![]const u8 {
        var v = try read.parseValue(a, json);
        if (v != .object) return error.BadChange;
        if (jv.str(v, "type")) |t| if (std.mem.eql(u8, t, "instance") and jv.arr(v, "children").len == 0) {
            if (jv.str(v, "component")) |cid| if (self.node(cid)) |main| {
                v = try self.instantiate(a, main, v);
            };
        };
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        var renames: std.ArrayList([2][]const u8) = .empty;
        try self.freshIds(a, &v, &seen, &renames);
        return Stringify.valueAlloc(a, v, .{});
    }

    fn freshIds(self: *Editor, a: Allocator, v: *Value, seen: *std.StringHashMapUnmanaged(void), renames: *std.ArrayList([2][]const u8)) !void {
        if (v.* != .object) return;
        const old = jv.str(v.*, "id") orelse "";
        var id = old;
        // A copy of an instance that got a new id follows it.
        for (renames.items) |r| {
            if (old.len > r[0].len and std.mem.startsWith(u8, old, r[0]) and old[r[0].len] == ';') {
                id = try std.fmt.allocPrint(a, "{s}{s}", .{ r[1], old[r[0].len..] });
                break;
            }
        }
        if (id.len == 0 or seen.contains(id) or self.sess.renderer.nodes.get(id) != null) id = try self.freshId();
        try seen.put(a, id, {});
        if (!std.mem.eql(u8, id, old)) {
            try v.object.put(a, "id", .{
                .string = id,
            });
            if (std.mem.eql(u8, jv.str(v.*, "type") orelse "", "instance") and old.len > 0) {
                try renames.append(a, .{ try prefixOf(a, old), try prefixOf(a, id) });
            }
        }
        if (v.object.getPtr("children")) |kids| if (kids.* == .array) {
            for (kids.array.items) |*c| try self.freshIds(a, c, seen, renames);
        };
    }

    /// An instance of `main` as Pubd JSON: the main's content with copy ids, under the
    /// fields `given` sets (its id, place, name).
    fn instantiate(self: *Editor, a: Allocator, main: *const m.Node, given: Value) !Value {
        const json = try write.nodeJson(a, main, .{});
        var v = try read.parseValue(a, json);
        const id = jv.str(given, "id") orelse "";
        var it = given.object.iterator();
        while (it.next()) |e| try v.object.put(a, e.key_ptr.*, e.value_ptr.*);
        try v.object.put(a, "type", .{
            .string = "instance",
        });
        try v.object.put(a, "component", .{
            .string = main.id,
        });
        if (given.object.get("name") == null) try v.object.put(a, "name", .{
            .string = main.name,
        });
        _ = v.object.orderedRemove("properties");
        _ = v.object.orderedRemove("transform");
        if (given.object.get("transform")) |t| try v.object.put(a, "transform", t);
        try v.object.put(a, "overrides", .{
            .object = .empty,
        });
        // Its id now, so the copies take its prefix.
        const tmp_id = if (id.len > 0 and self.sess.renderer.nodes.get(id) == null) id else try self.freshId();
        try v.object.put(a, "id", .{
            .string = tmp_id,
        });
        if (v.object.getPtr("children")) |kids| if (kids.* == .array) {
            const pre = try prefixOf(a, tmp_id);
            for (kids.array.items) |*c| try copyIds(a, c, pre);
        };
        return v;
    }

    /// Gives a subtree copied from a main the ids its copies take under prefix `pre`.
    fn copyIds(a: Allocator, v: *Value, pre: []const u8) !void {
        if (v.* != .object) return;
        const id = jv.str(v.*, "id") orelse return;
        try v.object.put(a, "id", .{
            .string = try std.fmt.allocPrint(a, "{s};{s}", .{ pre, local(id) }),
        });
        if (v.object.getPtr("children")) |kids| if (kids.* == .array) {
            for (kids.array.items) |*c| try copyIds(a, c, pre);
        };
    }

    /// An edit of a node inside an instance (or of a real instance) is an override: its
    /// keys are recorded on the instance that owns it.
    fn recordOverride(self: *Editor, n: *m.Node, json: []const u8) !void {
        const a = self.call.allocator();
        const o = (try self.ownerOf(a, n)) orelse return;
        if (o.inst.overrides == null) return;
        const v = try read.parseValue(a, json);
        var keys: std.ArrayList([]const u8) = .empty;
        var it = v.object.iterator();
        while (it.next()) |e| {
            const k = props.find(e.key_ptr.*) orelse continue;
            if (!k.override) continue;
            if (o.path.len == 0 and (std.mem.eql(u8, k.name, "transform") or std.mem.eql(u8, k.name, "component") or std.mem.eql(u8, k.name, "props"))) continue;
            if (overrides(o.inst, o.path, k.name)) continue;
            try keys.append(a, k.name);
        }
        if (keys.items.len == 0) return;
        const ovs = try editOverrides(a, o.inst, o.path, keys.items, true);
        try self.prim(.{
            .op = .set,
            .node = o.inst.id,
            .json = try std.fmt.allocPrint(a, "{{\"overrides\":{s}}}", .{ovs}),
        }, .derived);
    }

    // ------------------------------------------------------------------ propagation

    const Target = struct {
        inst: []const u8,
        change: Change,
    };

    /// Where a change made inside a main component goes in each of its instances (the
    /// change as it applies there), before it is applied.
    fn targets(self: *Editor, c: Change) ![]Target {
        const a = self.call.allocator();
        var out: std.ArrayList(Target) = .empty;
        const anchor_id = switch (c.op) {
            .set, .delete => c.node,
            .insert => c.parent,
            .move => c.node,
            .style, .variable, .collection => return out.items,
        };
        if (anchor_id.len == 0) return out.items;
        const anchor = self.node(anchor_id) orelse return out.items;
        const main = self.mainOf(anchor) orelse return out.items;
        // A move out of or into the main is a delete or an insert there.
        if (c.op == .move) {
            const into = if (c.parent.len > 0) self.node(c.parent) else null;
            const into_main = if (into) |p| self.mainOf(p) else null;
            if (into_main != main) return out.items;
        }
        const path = mainPath(main, anchor);
        for (try self.instancesOf(main.id)) |xid| {
            const x = self.node(xid) orelse continue;
            if (underSwap(x, path)) continue;
            var t = c;
            switch (c.op) {
                .set => {
                    const tid = try instId(a, x.id, path);
                    if (self.node(tid) == null) continue;
                    t.node = tid;
                    t.json = (try self.filterSet(a, x, path, c.json)) orelse continue;
                },
                .insert => {
                    if (overrides(x, path, "component")) continue;
                    const pid = try instId(a, x.id, path);
                    if (self.node(pid) == null) continue;
                    t.parent = pid;
                    var v = try read.parseValue(a, c.json);
                    try copyIds(a, &v, try prefixOf(a, x.id));
                    t.json = try Stringify.valueAlloc(a, v, .{});
                    t.node = jv.str(v, "id").?;
                },
                .delete => {
                    if (path.len == 0) continue;
                    const tid = try instId(a, x.id, path);
                    if (self.node(tid) == null) continue;
                    t.node = tid;
                },
                .move => {
                    const tid = try instId(a, x.id, path);
                    const p = self.node(c.parent) orelse continue;
                    const ppath = mainPath(main, p);
                    if (underSwap(x, ppath) or overrides(x, ppath, "component")) continue;
                    const pid = try instId(a, x.id, ppath);
                    if (self.node(tid) == null or self.node(pid) == null) continue;
                    t.node = tid;
                    t.parent = pid;
                },
                .style, .variable, .collection => unreachable,
            }
            try out.append(a, .{
                .inst = x.id,
                .change = t,
            });
        }
        return out.items;
    }

    /// The keys of a set that reach instance `x` at `path`: not what it overrides, nor
    /// what belongs to the main or to the instance itself.
    fn filterSet(self: *Editor, a: Allocator, x: *const m.Node, path: []const u8, json: []const u8) !?[]const u8 {
        _ = self;
        var v = try read.parseValue(a, json);
        var out: std.json.ObjectMap = .empty;
        var it = v.object.iterator();
        while (it.next()) |e| {
            const k = e.key_ptr.*;
            if (std.mem.eql(u8, k, "overrides") or std.mem.eql(u8, k, "props") or std.mem.eql(u8, k, "properties") or std.mem.eql(u8, k, "type")) continue;
            if (path.len == 0 and (std.mem.eql(u8, k, "transform") or std.mem.eql(u8, k, "component"))) continue;
            if (overrides(x, path, k)) continue;
            try out.put(a, k, e.value_ptr.*);
        }
        if (out.count() == 0) return null;
        return try Stringify.valueAlloc(a, Value{
            .object = out,
        }, .{});
    }

    /// Takes a change made inside a main component to its instances.
    fn propagate(self: *Editor, c: Change) anyerror!void {
        const ts = try self.targets(c);
        try self.propagateTargets(c, ts);
    }

    fn propagateTargets(self: *Editor, c: Change, ts: []const Target) anyerror!void {
        _ = c;
        if (ts.len == 0) return;
        for (ts) |t| {
            const x = self.node(t.inst) orelse continue;
            const main = self.node(x.component orelse continue) orelse continue;
            switch (t.change.op) {
                .delete, .move => {
                    const sub = try self.targets(t.change);
                    try self.prim(t.change, .derived);
                    try self.propagateTargets(t.change, sub);
                },
                else => {
                    try self.prim(t.change, .derived);
                    try self.propagate(t.change);
                },
            }
            // Geometry from the main fits an instance of another size by its rules.
            if (x.size.x != main.size.x or x.size.y != main.size.y) {
                const geometric = switch (t.change.op) {
                    .set => (try hasKey(self.call.allocator(), t.change.json, "transform")) or (try hasKey(self.call.allocator(), t.change.json, "size")),
                    .insert, .move => true,
                    else => false,
                };
                if (geometric) try self.refits.append(self.gpa, try self.call.allocator().dupe(u8, x.id));
            }
        }
    }

    // ------------------------------------------------------------------ instances

    /// Applies a change set off by another (`mode` derived or sync) with what it sets
    /// off in turn; replaying applies it alone.
    fn run(self: *Editor, c: Change, mode: Mode) anyerror!void {
        if (mode == .replay) return self.prim(c, mode);
        const ts = try self.targets(c);
        try self.prim(c, mode);
        try self.propagateTargets(c, ts);
    }

    /// Whether path `p` lies strictly under `base` ("" the instance itself).
    fn isUnder(p: []const u8, base: []const u8) bool {
        if (base.len == 0) return p.len > 0;
        return p.len > base.len + 1 and std.mem.startsWith(u8, p, base) and p[base.len] == ';';
    }

    /// Sets instance `id`'s overrides to `list`.
    fn setOverrides(self: *Editor, id: []const u8, list: []const Ov, mode: Mode) !void {
        const a = self.call.allocator();
        try self.prim(.{
            .op = .set,
            .node = id,
            .json = try std.fmt.allocPrint(a, "{{\"overrides\":{s}}}", .{try overridesJson(a, list)}),
        }, mode);
    }

    fn copyOverrides(a: Allocator, ov: m.Override) !Ov {
        var keys: std.ArrayList([]const u8) = .empty;
        try keys.appendSlice(a, ov.keys);
        return .{
            .path = ov.path,
            .keys = keys,
        };
    }

    /// Gives instance `nid` its main's content anew (after a swap). With `carry`, what
    /// its owner overrides on layers below it stays on the layers of the same names.
    fn rebuild(self: *Editor, nid: []const u8, carry: bool, mode: Mode) !void {
        const a = self.call.allocator();
        const n0 = self.node(nid) orelse return;
        const main = self.node(n0.component orelse return) orelse return;
        const owner = try self.ownerOf(a, n0);
        const Carried = struct {
            names: []const u8,
            keys: []const []const u8,
            values: []const u8,
        };
        var carried: std.ArrayList(Carried) = .empty;
        var kept: std.ArrayList(Ov) = .empty;
        var owner_id: ?[]const u8 = null;
        if (owner) |o| if (o.inst.overrides) |ovs| {
            owner_id = o.inst.id;
            for (ovs) |ov| {
                if (!isUnder(ov.path, o.path)) {
                    try kept.append(a, try copyOverrides(a, ov));
                    continue;
                }
                if (!carry) continue;
                const old = self.node(try instId(a, o.inst.id, ov.path)) orelse continue;
                try carried.append(a, .{
                    .names = try self.namePath(a, n0, old),
                    .keys = ov.keys,
                    .values = try props.values(a, old, ov.keys),
                });
            }
        };
        // The new content: the main's, with the copies' ids.
        const json = try write.nodeJson(a, main, .{});
        var v = try read.parseValue(a, json);
        const pre = try prefixOf(a, nid);
        var kids: []Value = &.{};
        if (v.object.getPtr("children")) |k| if (k.* == .array) {
            for (k.array.items) |*c| try copyIds(a, c, pre);
            kids = k.array.items;
        };
        // Out with the old.
        while (true) {
            const n = self.node(nid) orelse return;
            if (n.children.len == 0) break;
            try self.run(.{
                .op = .delete,
                .node = n.children[n.children.len - 1].id,
            }, mode);
        }
        const n = self.node(nid) orelse return;
        // The new main's own look, but for what the instance overrides on itself.
        var names: std.ArrayList([]const u8) = .empty;
        for (&props.keys) |*k| {
            if (!k.override or k.text) continue;
            if (std.mem.eql(u8, k.name, "transform") or std.mem.eql(u8, k.name, "component") or std.mem.eql(u8, k.name, "props") or std.mem.eql(u8, k.name, "name") or std.mem.eql(u8, k.name, "size")) continue;
            if (owner) |o| if (overrides(o.inst, o.path, k.name)) continue;
            try names.append(a, k.name);
        }
        const want = try props.values(a, main, names.items);
        if (!std.mem.eql(u8, want, try props.values(a, n, names.items))) try self.run(.{
            .op = .set,
            .node = nid,
            .json = want,
        }, mode);
        const n2 = self.node(nid) orelse return;
        if (n2.size.x != main.size.x or n2.size.y != main.size.y) {
            const sizing = n2.sizing orelse m.Sizing{};
            if (sizing.w != .fill and sizing.h != .fill) try self.run(.{
                .op = .set,
                .node = nid,
                .json = try props.values(a, main, &.{"size"}),
            }, mode);
        }
        // The main's resolved stroke outline fits the main's size, not one the instance
        // keeps of its own.
        if (self.node(nid)) |n3| if (n3.stroke.outline.len > 0 and (n3.size.x != main.size.x or n3.size.y != main.size.y)) try self.run(.{
            .op = .set,
            .node = nid,
            .json = try strokeWithoutOutline(a, n3),
        }, mode);
        for (kids, 0..) |c, k| try self.run(.{
            .op = .insert,
            .parent = nid,
            .index = @intCast(k),
            .node = jv.str(c, "id").?,
            .json = try Stringify.valueAlloc(a, c, .{}),
        }, mode);
        // The overrides on layers of the same names, back.
        if (owner_id) |oid| {
            for (carried.items) |cr| {
                const top = self.node(nid) orelse break;
                const target = self.byNamePath(top, cr.names) orelse continue;
                const tid = target.id;
                try self.run(.{
                    .op = .set,
                    .node = tid,
                    .json = cr.values,
                }, mode);
                const p = (try pathIn(a, oid, tid)) orelse continue;
                var keys: std.ArrayList([]const u8) = .empty;
                try keys.appendSlice(a, cr.keys);
                try kept.append(a, .{
                    .path = p,
                    .keys = keys,
                });
            }
            try self.setOverrides(oid, kept.items, mode);
        }
        try self.markLayout(nid);
    }

    /// The names from `top` (exclusive) down to `n`, joined by `/`.
    fn namePath(self: *Editor, a: Allocator, top: *const m.Node, n: *const m.Node) ![]const u8 {
        var names: std.ArrayList([]const u8) = .empty;
        var cur = n.id;
        while (!std.mem.eql(u8, cur, top.id)) {
            const c = self.node(cur) orelse break;
            try names.append(a, c.name);
            cur = self.parents.get(cur) orelse break;
            if (cur.len == 0) break;
        }
        std.mem.reverse([]const u8, names.items);
        return std.mem.join(a, "/", names.items);
    }

    fn byNamePath(self: *Editor, top: *m.Node, names: []const u8) ?*m.Node {
        _ = self;
        var cur = top;
        var it = std.mem.splitScalar(u8, names, '/');
        while (it.next()) |name| {
            cur = for (cur.children) |*c| {
                if (std.mem.eql(u8, c.name, name)) break c;
            } else return null;
        }
        return if (cur == top) null else cur;
    }

    /// Puts the overrides of `id` (an instance or a node inside one) back to the main:
    /// `keys` of it, or all of its own (all the instance's, for an instance).
    fn resetOverrides(self: *Editor, id: []const u8, keys_v: ?[]const Value) !void {
        const a = self.call.allocator();
        const n = self.node(id) orelse return error.NoSuchNode;
        try self.prepare(n);
        const o = (try self.ownerOf(a, n)) orelse return error.NotAnInstance;
        const x = o.inst;
        const xid = x.id;
        const main = self.node(x.component orelse return error.NoMainComponent) orelse return error.NoMainComponent;
        const ovs = x.overrides orelse return;
        const Item = struct {
            path: []const u8,
            keys: []const []const u8,
            swap: bool,
        };
        var items: std.ArrayList(Item) = .empty;
        const whole = o.path.len == 0 and keys_v == null;
        for (ovs) |ov| {
            if (!whole and !std.mem.eql(u8, ov.path, o.path)) continue;
            var keys: std.ArrayList([]const u8) = .empty;
            var swap = false;
            for (ov.keys) |k| {
                if (keys_v) |ks| {
                    var want = false;
                    for (ks) |kv| want = want or (kv == .string and std.mem.eql(u8, kv.string, k));
                    if (!want) continue;
                }
                swap = swap or std.mem.eql(u8, k, "component");
                try keys.append(a, k);
            }
            if (keys.items.len > 0) try items.append(a, .{
                .path = ov.path,
                .keys = keys.items,
                .swap = swap,
            });
        }
        if (items.items.len == 0) return;
        // The record without them (and without what lies under a swap put back).
        var list: std.ArrayList(Ov) = .empty;
        for (ovs) |ov| {
            var gone = false;
            for (items.items) |it| gone = gone or (it.swap and isUnder(ov.path, it.path));
            if (gone) continue;
            var c = try copyOverrides(a, ov);
            for (items.items) |it| if (std.mem.eql(u8, it.path, ov.path)) {
                var i: usize = 0;
                while (i < c.keys.items.len) {
                    var drop = false;
                    for (it.keys) |k| drop = drop or std.mem.eql(u8, k, c.keys.items[i]);
                    if (drop) _ = c.keys.orderedRemove(i) else i += 1;
                }
            };
            if (c.keys.items.len > 0) try list.append(a, c);
        }
        try self.setOverrides(xid, list.items, .derived);
        // Deepest first: a swap put back rebuilds what is under it.
        std.mem.sort(Item, items.items, {}, struct {
            fn lt(_: void, p: Item, q: Item) bool {
                return p.path.len > q.path.len;
            }
        }.lt);
        for (items.items) |it| {
            const tid = try instId(a, xid, it.path);
            if (self.node(tid) == null) continue;
            const r = (try self.mainNode(a, main, it.path)) orelse continue;
            try self.run(.{
                .op = .set,
                .node = tid,
                .json = try props.values(a, r, it.keys),
            }, .user);
            if (it.swap) try self.rebuild(tid, false, .derived);
            for (it.keys) |k| {
                if (it.path.len > 0 and (std.mem.eql(u8, k, "transform") or std.mem.eql(u8, k, "size"))) try self.refits.append(self.gpa, xid);
            }
            try self.markLayout(tid);
        }
    }

    /// The component set (or older files' component holding components) that main
    /// component `main` is a variant of.
    fn setOf(self: *Editor, main: *m.Node) ?*m.Node {
        const p = self.parentOf(main.id) orelse return null;
        if (p.kind == .component_set) return p;
        if (p.kind == .component) for (p.children) |c| {
            if (c.kind == .component) return p;
        };
        return null;
    }

    /// A variant's values from its name ("State=Hover, Size=Large").
    fn variantValue(name: []const u8, prop: []const u8) ?[]const u8 {
        var it = std.mem.splitSequence(u8, name, ",");
        while (it.next()) |part| {
            const eq = std.mem.indexOfScalar(u8, part, '=') orelse continue;
            const k = std.mem.trim(u8, part[0..eq], " ");
            if (std.mem.eql(u8, k, prop)) return std.mem.trim(u8, part[eq + 1 ..], " ");
        }
        return null;
    }

    fn sameVariant(a_name: []const u8, b_name: []const u8, except: []const u8) bool {
        var it = std.mem.splitSequence(u8, a_name, ",");
        while (it.next()) |part| {
            const eq = std.mem.indexOfScalar(u8, part, '=') orelse continue;
            const k = std.mem.trim(u8, part[0..eq], " ");
            if (std.mem.eql(u8, k, except)) continue;
            const va = std.mem.trim(u8, part[eq + 1 ..], " ");
            const vb = variantValue(b_name, k) orelse return false;
            if (!std.mem.eql(u8, va, vb)) return false;
        }
        return true;
    }

    /// Sets component property `prop` of instance `id` to `value` (null: back to the
    /// main's default). A variant property switches the instance to that variant.
    fn setProperty(self: *Editor, id: []const u8, prop: []const u8, value: Value) !void {
        const a = self.call.allocator();
        const x = self.node(id) orelse return error.NoSuchNode;
        if (x.kind != .instance) return error.NotAnInstance;
        const main = self.node(x.component orelse return error.NoMainComponent) orelse return error.NoMainComponent;
        const set = self.setOf(main);
        // A variant property: the sibling with the same values but this one.
        if (set) |st| if (variantValue(main.name, prop) != null) {
            const want = if (value == .string) value.string else return error.BadChange;
            for (st.children) |*c| {
                if (c.kind != .component) continue;
                const cv = variantValue(c.name, prop) orelse continue;
                if (!std.mem.eql(u8, cv, want) or !sameVariant(main.name, c.name, prop)) continue;
                const json = try std.fmt.allocPrint(a, "{{\"component\":{f}}}", .{std.json.fmt(c.id, .{})});
                return self.userChange(.{
                    .op = .set,
                    .node = x.id,
                    .json = json,
                });
            }
            return error.NoSuchVariant;
        };
        // The definition, for its kind and default.
        var def: ?m.PropDef = null;
        for (main.properties) |d| if (std.mem.eql(u8, d.id, prop)) {
            def = d;
        };
        if (def == null) if (set) |st| for (st.properties) |d| if (std.mem.eql(u8, d.id, prop)) {
            def = d;
        };
        // A property only its layers name (a variant's own copy of the set's): its kind
        // is the field they bind.
        const d = def orelse m.PropDef{
            .id = prop,
            .kind = boundKind(x, prop) orelse return error.NoSuchProperty,
        };
        const field: []const u8 = switch (d.kind) {
            .boolean => "visible",
            .text => "text",
            .instance_swap => "component",
            .variant => return error.NoSuchVariant,
        };
        // The layers bound to it, and the new value of each.
        var bound: std.ArrayList(*m.Node) = .empty;
        try collectBound(a, x, prop, d.kind, &bound);
        const to_default = value == .null;
        const val_json = if (to_default) d.default else try Stringify.valueAlloc(a, value, .{});
        for (bound.items) |b| {
            if (to_default) {
                const keys = [_]Value{.{
                    .string = field,
                }};
                try self.resetOverrides(b.id, &keys);
            } else {
                const json = try std.fmt.allocPrint(a, "{{{f}:{s}}}", .{ std.json.fmt(field, .{}), val_json });
                try self.userChange(.{
                    .op = .set,
                    .node = b.id,
                    .json = json,
                });
            }
        }
        // The value on the instance.
        var out: std.Io.Writer.Allocating = .init(a);
        var s: Stringify = .{
            .writer = &out.writer,
        };
        const xn = self.node(id) orelse return;
        try s.beginObject();
        try s.objectField("props");
        try s.beginObject();
        for (xn.props) |p| {
            if (std.mem.eql(u8, p.id, prop)) continue;
            try s.objectField(p.id);
            try s.beginWriteRaw();
            try s.writer.writeAll(p.value);
            s.endWriteRaw();
        }
        if (!to_default) {
            try s.objectField(prop);
            try s.beginWriteRaw();
            try s.writer.writeAll(val_json);
            s.endWriteRaw();
        }
        try s.endObject();
        try s.endObject();
        try self.prim(.{
            .op = .set,
            .node = xn.id,
            .json = out.written(),
        }, .derived);
    }

    /// The kind of property `prop` going by what layers under `n` bind to it.
    fn boundKind(n: *const m.Node, prop: []const u8) ?m.PropKind {
        for (n.children) |*c| {
            if (c.bind.visible) |b| if (std.mem.eql(u8, b, prop)) return .boolean;
            if (c.bind.text) |b| if (std.mem.eql(u8, b, prop)) return .text;
            if (c.bind.component) |b| if (std.mem.eql(u8, b, prop)) return .instance_swap;
            if (c.kind != .instance) if (boundKind(c, prop)) |k| return k;
        }
        return null;
    }

    fn collectBound(a: Allocator, n: *m.Node, prop: []const u8, kind: m.PropKind, out: *std.ArrayList(*m.Node)) !void {
        for (n.children) |*c| {
            const b = switch (kind) {
                .boolean => c.bind.visible,
                .text => c.bind.text,
                .instance_swap => c.bind.component,
                .variant => null,
            };
            if (b) |id| if (std.mem.eql(u8, id, prop)) try out.append(a, c);
            // A nested instance's own properties are its own.
            if (c.kind != .instance) try collectBound(a, c, prop, kind, out);
        }
    }

    /// Instance `id` becomes a frame with the same look, following nothing; nested
    /// instances become instances of their own, with the overrides under them.
    fn detach(self: *Editor, id: []const u8) !void {
        const a = self.call.allocator();
        const x = self.node(id) orelse return error.NoSuchNode;
        if (!self.isRealInstance(x)) return error.NotAnInstance;
        try self.prepare(x);
        const ovs = x.overrides orelse &.{};
        // Nested instances directly under it take the overrides below them.
        var nested: std.ArrayList(*m.Node) = .empty;
        try directInstances(a, x, &nested);
        for (nested.items) |nn| {
            const p = (try pathIn(a, x.id, nn.id)) orelse continue;
            var list: std.ArrayList(Ov) = .empty;
            for (ovs) |ov| {
                const rel: []const u8 = if (std.mem.eql(u8, ov.path, p)) "" else if (ov.path.len > p.len and std.mem.startsWith(u8, ov.path, p) and ov.path[p.len] == ';') ov.path[p.len + 1 ..] else continue;
                var keys: std.ArrayList([]const u8) = .empty;
                try keys.appendSlice(a, ov.keys);
                try list.append(a, .{
                    .path = rel,
                    .keys = keys,
                });
            }
            try self.prim(.{
                .op = .set,
                .node = nn.id,
                .json = try std.fmt.allocPrint(a, "{{\"overrides\":{s}}}", .{try overridesJson(a, list.items)}),
            }, .derived);
        }
        const xx = self.node(id) orelse return;
        try self.prim(.{
            .op = .set,
            .node = xx.id,
            .json = "{\"type\":\"frame\",\"component\":null,\"overrides\":null,\"props\":null}",
        }, .user);
        self.instances_ok = false;
    }

    fn directInstances(a: Allocator, n: *m.Node, out: *std.ArrayList(*m.Node)) !void {
        for (n.children) |*c| {
            if (c.kind == .instance) {
                try out.append(a, c);
                continue;
            }
            try directInstances(a, c, out);
        }
    }

    // ------------------------------------------------------------------ syncing

    /// Brings the instances on page `page_id` of main components this session changed up
    /// to them: their content anew from the main, with their overrides.
    fn syncPage(self: *Editor, page_id: []const u8) !void {
        const pi = self.pageIndexById(page_id) orelse return;
        if (!self.indexed) return;
        self.beginCall();
        defer self.endCall();
        var it = self.originals.keyIterator();
        var mains: std.ArrayList([]const u8) = .empty;
        while (it.next()) |k| try mains.append(self.call.allocator(), k.*);
        for (mains.items) |mid| try self.syncInstances(mid, pi);
        try self.flush();
    }

    /// Re-resolves the real instances of main `mid` on page `pi` (unrecorded).
    fn syncInstances(self: *Editor, mid: []const u8, pi: usize) !void {
        for (try self.instancesOf(mid)) |xid| {
            if (self.pageOf(xid) != pi) continue;
            const x = self.node(xid) orelse continue;
            try self.ensureOverrides(x);
            try self.resync(xid, .sync);
        }
    }

    /// Instance `xid`'s content anew from its main, keeping what it overrides.
    fn resync(self: *Editor, xid: []const u8, mode: Mode) !void {
        const a = self.call.allocator();
        const x = self.node(xid) orelse return;
        const main = self.node(x.component orelse return) orelse return;
        // The root's own keys that follow the main.
        var names: std.ArrayList([]const u8) = .empty;
        for (&props.keys) |*k| {
            if (!k.override or k.text) continue;
            if (std.mem.eql(u8, k.name, "transform") or std.mem.eql(u8, k.name, "component") or std.mem.eql(u8, k.name, "props")) continue;
            if (overrides(x, "", k.name)) continue;
            try names.append(a, k.name);
        }
        const want = try props.values(a, main, names.items);
        const have = try props.values(a, x, names.items);
        if (!std.mem.eql(u8, want, have)) try self.run(.{
            .op = .set,
            .node = xid,
            .json = want,
        }, mode);
        // The content: the main's, with the overridden values of the old copies.
        const pre = try prefixOf(a, xid);
        const json = try write.nodeJson(a, main, .{});
        var v = try read.parseValue(a, json);
        var kids: []Value = &.{};
        if (v.object.getPtr("children")) |k| if (k.* == .array) {
            for (k.array.items) |*c| try copyIds(a, c, pre);
            kids = k.array.items;
        };
        const xs = self.node(xid) orelse return;
        for (kids) |*c| try self.keepOverridden(a, xs, c);
        while (true) {
            const xn = self.node(xid) orelse return;
            if (xn.children.len == 0) break;
            try self.run(.{
                .op = .delete,
                .node = xn.children[xn.children.len - 1].id,
            }, mode);
        }
        for (kids, 0..) |c, k| try self.run(.{
            .op = .insert,
            .parent = xid,
            .index = @intCast(k),
            .node = jv.str(c, "id").?,
            .json = try Stringify.valueAlloc(a, c, .{}),
        }, mode);
        try self.refits.append(self.gpa, xid);
    }

    /// In a copy about to replace the old one, the values the instance overrides (and
    /// the content of a nested instance it swapped).
    fn keepOverridden(self: *Editor, a: Allocator, x: *const m.Node, v: *Value) anyerror!void {
        const id = jv.str(v.*, "id") orelse return;
        const path = (try pathIn(a, x.id, id)) orelse return;
        const keys = overridesAt(x, path);
        if (keys.len > 0) if (self.node(id)) |old| {
            const vals = try read.parseValue(a, try props.values(a, old, keys));
            var it = vals.object.iterator();
            while (it.next()) |e| {
                if (e.value_ptr.* == .null) {
                    _ = v.object.orderedRemove(e.key_ptr.*);
                } else try v.object.put(a, e.key_ptr.*, e.value_ptr.*);
            }
            if (overrides(x, path, "component")) {
                // A swapped nested instance keeps its content as it is.
                const kj = try write.nodeJson(a, old, .{});
                const kv = try read.parseValue(a, kj);
                if (kv.object.get("children")) |kids| {
                    try v.object.put(a, "children", kids);
                } else _ = v.object.orderedRemove("children");
                return;
            }
        };
        if (v.object.getPtr("children")) |kids| if (kids.* == .array) {
            for (kids.array.items) |*c| try self.keepOverridden(a, x, c);
        };
    }

    /// After undo or redo: loaded pages that did not take part in the step bring their
    /// instances of the mains it changed up to them.
    fn syncUncovered(self: *Editor, s: *const Step) !void {
        if (s.mains.items.len == 0) return;
        const d = try self.doc();
        for (d.pages, 0..) |pg, i| {
            if (!self.sess.pageLoaded(i)) continue;
            var covered = false;
            for (s.covered.items) |c| covered = covered or std.mem.eql(u8, c, pg.id);
            if (covered) continue;
            for (s.mains.items) |mid| try self.syncInstances(mid, i);
        }
        try self.flush();
    }

    /// Fits instance `id` to its main's geometry and then to its own size, as the
    /// main's constraints and auto layout place things in a box of that size.
    fn refit(self: *Editor, id: []const u8, log: *std.ArrayList(lay.Snap)) !void {
        const a = self.call.allocator();
        const x = self.node(id) orelse return;
        const main = self.node(x.component orelse return) orelse return;
        const own = x.size;
        try self.copyGeometry(a, x, x, main, log);
        try log.append(self.gpa, .{
            .node = x,
            .size = x.size,
            .transform = x.transform,
        });
        x.size = main.size;
        const path = try self.pathTo(a, id);
        var options = self.layout_options;
        options.log = log;
        options.fonts = &self.sess.fonts;
        options.size = own;
        _ = try lay.relayoutPath(self.gpa, path, options);
    }

    fn copyGeometry(self: *Editor, a: Allocator, x: *const m.Node, xn: *m.Node, rn: *const m.Node, log: *std.ArrayList(lay.Snap)) !void {
        if (xn.children.len != rn.children.len) return;
        for (xn.children, rn.children) |*c, *r| {
            const p = (try pathIn(a, x.id, c.id)) orelse continue;
            try log.append(self.gpa, .{
                .node = c,
                .size = c.size,
                .transform = c.transform,
            });
            if (!overrides(x, p, "transform")) c.transform = r.transform;
            if (!overrides(x, p, "size")) c.size = r.size;
            if (overrides(x, p, "component")) continue;
            try self.copyGeometry(a, x, c, r, log);
        }
    }

    // ------------------------------------------------------------------ layout

    fn markLayout(self: *Editor, id: []const u8) !void {
        try self.layout_dirty.append(self.gpa, try self.call.allocator().dupe(u8, id));
    }

    /// Lays out what the call's changes left dirty, and records what layout moved or
    /// resized as derived changes.
    fn flush(self: *Editor) !void {
        try self.resolveVars(.derived);
        if (self.layout_dirty.items.len == 0 and self.refits.items.len == 0) return;
        const a = self.call.allocator();
        var log: std.ArrayList(lay.Snap) = .empty;
        defer log.deinit(self.gpa);
        var options = self.layout_options;
        options.log = &log;
        options.fonts = &self.sess.fonts;
        var done: std.StringHashMapUnmanaged(void) = .empty;
        for (self.refits.items) |id| {
            if (done.contains(id)) continue;
            try done.put(a, id, {});
            try self.refit(id, &log);
        }
        self.refits.clearRetainingCapacity();
        done.clearRetainingCapacity();
        for (self.layout_dirty.items) |id| {
            if (done.contains(id)) continue;
            try done.put(a, id, {});
            if (self.node(id) == null) continue;
            const path = self.pathTo(a, id) catch continue;
            if (path.len < 2) continue;
            _ = try lay.relayoutPath(self.gpa, path, options);
        }
        self.layout_dirty.clearRetainingCapacity();
        // What changed: each node's first entry holds what it was.
        var first: std.AutoHashMapUnmanaged(*m.Node, lay.Snap) = .empty;
        for (log.items) |s| {
            const got = try first.getOrPut(a, s.node);
            if (!got.found_existing) got.value_ptr.* = s;
        }
        var changed: std.ArrayList(lay.Snap) = .empty;
        var it = first.valueIterator();
        while (it.next()) |s| {
            const n = s.node;
            if (std.mem.eql(u8, std.mem.asBytes(&n.size), std.mem.asBytes(&s.size)) and std.mem.eql(u8, std.mem.asBytes(&n.transform), std.mem.asBytes(&s.transform))) continue;
            try changed.append(a, s.*);
        }
        if (changed.items.len == 0) return;
        // The rects painted before and after: of the outermost changed nodes.
        var is_changed: std.AutoHashMapUnmanaged(*m.Node, void) = .empty;
        for (changed.items) |s| try is_changed.put(a, s.node, {});
        var tops: std.ArrayList(*m.Node) = .empty;
        for (changed.items) |s| {
            const p = self.parentOf(s.node.id);
            if (p == null or !is_changed.contains(p.?)) try tops.append(a, s.node);
        }
        const Now = struct {
            size: geom.Vec2,
            transform: Affine,
        };
        const now = try a.alloc(Now, changed.items.len);
        for (changed.items, now) |s, *x| {
            x.* = .{
                .size = s.node.size,
                .transform = s.node.transform,
            };
            s.node.size = s.size;
            s.node.transform = s.transform;
        }
        for (tops.items) |n| try self.addDamage(self.pageOf(n.id), self.paintedRect(n));
        // The old values, as a change puts them back.
        const olds = try a.alloc([]const u8, changed.items.len);
        for (changed.items, olds) |s, *o| o.* = try props.values(a, s.node, &.{ "transform", "size" });
        for (changed.items, now) |s, x| {
            s.node.size = x.size;
            s.node.transform = x.transform;
        }
        for (tops.items) |n| try self.addDamage(self.pageOf(n.id), self.paintedRect(n));
        for (changed.items, olds) |s, old| {
            const n = s.node;
            const fwd: Change = .{
                .op = .set,
                .node = n.id,
                .json = try props.values(a, n, &.{ "transform", "size" }),
            };
            try self.touch(n);
            self.markDirty(self.pageOf(n.id));
            try self.emit(fwd);
            try self.record(fwd, .{
                .op = .set,
                .node = n.id,
                .json = old,
            }, true);
        }
        // A stroke's resolved outline was worked out at the old size: past a resize it
        // no longer fits, and the stroke is drawn from its settings instead.
        const marks = self.layout_dirty.items.len;
        for (changed.items) |sn| {
            const n = sn.node;
            if (n.stroke.outline.len == 0) continue;
            if (n.size.x == sn.size.x and n.size.y == sn.size.y) continue;
            try self.prim(.{
                .op = .set,
                .node = n.id,
                .json = try strokeWithoutOutline(a, n),
            }, .derived);
        }
        self.layout_dirty.shrinkRetainingCapacity(marks);
    }

    /// The node's `stroke` as a set puts it, without its resolved outline.
    fn strokeWithoutOutline(a: Allocator, n: *const m.Node) ![]const u8 {
        var v = try read.parseValue(a, try props.values(a, n, &.{"stroke"}));
        if (v == .object) if (v.object.getPtr("stroke")) |st| if (st.* == .object) {
            _ = st.object.orderedRemove("outline");
        };
        if (v == .object and v.object.get("stroke") == null) try v.object.put(a, "stroke", .null);
        return Stringify.valueAlloc(a, v, .{});
    }

    // ------------------------------------------------------------------ primitives

    /// Applies one change as it is; records it (with its inverse) unless replaying,
    /// and notes what it touched.
    fn prim(self: *Editor, c: Change, mode: Mode) anyerror!void {
        const a = self.call.allocator();
        const d = try self.doc();
        var inv: Change = undefined;
        var page: ?usize = null;
        switch (c.op) {
            .set => {
                if (c.node.len == 0) {
                    // The document: its name.
                    const v = try read.parseValue(a, c.json);
                    const old = try std.fmt.allocPrint(a, "{{\"name\":{f}}}", .{std.json.fmt(d.name, .{})});
                    if (jv.get(v, "name")) |nm| d.name = if (nm == .string) try self.arena.allocator().dupe(u8, nm.string) else "";
                    inv = .{
                        .op = .set,
                        .node = "",
                        .json = old,
                    };
                    self.pages_changed = true;
                } else {
                    const n = self.node(c.node) orelse return error.NoSuchNode;
                    page = self.pageOf(n.id);
                    if (page) |pg| if (!self.sess.pageLoaded(pg)) return error.PageNotLoaded;
                    const v = try read.parseValue(a, c.json);
                    if (v != .object) return error.BadChange;
                    var names: std.ArrayList([]const u8) = .empty;
                    var layout = false;
                    var visual = false;
                    var it = v.object.iterator();
                    while (it.next()) |e| {
                        const k = props.find(e.key_ptr.*) orelse return error.UnknownKey;
                        layout = layout or k.layout;
                        visual = visual or k.visual;
                        try names.append(a, k.name);
                    }
                    inv = .{
                        .op = .set,
                        .node = n.id,
                        .json = try props.values(a, n, names.items),
                    };
                    const before = if (visual) self.paintedRect(n) else geom.Rect.empty;
                    const was_kind = n.kind;
                    // Paints that may only change colour: what they were, to tell.
                    const recolour = visual and colourKeysOnly(names.items, self.paint_only);
                    const was_paints: Paints = .of(n);
                    try props.apply(self.gpa, self.arena.allocator(), n, v.object);
                    if (mode != .replay and !self.resolving and d.variables.len > 0) {
                        // Its bound fields (and, with a mode set, everything in it) follow
                        // the variables in the modes it is in.
                        if (v.object.get("modes") != null) {
                            try self.markVars(&self.var_trees, n.id);
                        } else if (pubd_vars.hasBindings(n)) try self.markVars(&self.var_nodes, n.id);
                    }
                    if (n.kind != was_kind or v.object.get("component") != null) self.instances_ok = false;
                    if (visual) {
                        try self.addDamage(page, before);
                        try self.addDamage(page, self.paintedRect(n));
                        if (recolour and was_paints.sameButColours(.of(n))) {
                            try self.touchColours(n);
                        } else if (self.paint_only or paintKeysOnly(names.items)) try self.touchPaints(n) else try self.touch(n);
                    }
                    if (self.isTopLevel(n.id)) self.pages_changed = true;
                    if (layout and mode != .replay and !self.paint_only) {
                        // A move alone changes nothing inside the node: only what holds it.
                        const moved_only = names.items.len == 1 and std.mem.eql(u8, names.items[0], "transform");
                        if (!moved_only) try self.markLayout(n.id);
                        if (self.parentOf(n.id)) |p| if (p.kind != .page and (p.kind == .group or p.layout != null)) try self.markLayout(p.id);
                    }
                }
            },
            .insert => {
                const built = try read.nodeFromJson(self.gpa, self.arena.allocator(), c.json, .{});
                if (self.sess.renderer.nodes.get(built.id) != null) return error.IdTaken;
                if (c.parent.len == 0) {
                    try self.insertPage(built, c.index, c.file);
                    page = null;
                    self.pages_changed = true;
                } else {
                    const p = self.node(c.parent) orelse return error.NoSuchParent;
                    if (!(p.kind.isContainer() or p.kind == .group or p.kind == .page or p.kind == .boolean)) return error.NotAContainer;
                    page = self.pageOf(p.id);
                    if (page) |pg| if (!self.sess.pageLoaded(pg)) return error.PageNotLoaded;
                    const at = @min(c.index, p.children.len);
                    try self.setChildren(p, try insertAt(self.arena.allocator(), p.children, at, built));
                    const added = &p.children[at];
                    try self.indexTree(added, p.id);
                    try self.indexNodes(added);
                    try self.touch(added);
                    try self.addDamage(page, self.paintedRect(added));
                    if (mode != .replay and !self.resolving and d.variables.len > 0) try self.markVars(&self.var_trees, added.id);
                    if (p.kind == .page) self.pages_changed = true;
                    if (mode != .replay) {
                        try self.markLayout(added.id);
                        if (p.kind != .page) try self.markLayout(p.id);
                    }
                }
                self.instances_ok = false;
                inv = .{
                    .op = .delete,
                    .node = built.id,
                };
            },
            .delete => {
                const n = self.node(c.node) orelse return error.NoSuchNode;
                const pid = self.parents.get(n.id) orelse return error.NoSuchNode;
                const json = try write.nodeJson(a, n, .{});
                if (pid.len == 0) {
                    const at = self.pageIndexById(n.id) orelse return error.NoSuchNode;
                    // A page never read goes as it is: undo lists it again, still in its
                    // own file (which stays), and reads it when it is shown.
                    const file: []const u8 = if (self.sess.pageLoaded(at)) "" else self.sess.pageFile(at) orelse "";
                    inv = .{
                        .op = .insert,
                        .parent = "",
                        .index = @intCast(at),
                        .node = n.id,
                        .json = json,
                        .file = file,
                    };
                    try self.removePage(at);
                    self.pages_changed = true;
                } else {
                    const p = self.node(pid) orelse return error.NoSuchParent;
                    page = self.pageOf(p.id);
                    const at = indexIn(p, n.id) orelse return error.NoSuchNode;
                    inv = .{
                        .op = .insert,
                        .parent = p.id,
                        .index = @intCast(at),
                        .node = n.id,
                        .json = json,
                    };
                    try self.addDamage(page, self.paintedRect(n));
                    self.forgetTree(n);
                    self.unindexTree(n);
                    try self.unindexNodes(n);
                    try self.setChildren(p, try removeAt(self.arena.allocator(), p.children, at));
                    try self.touchTree(p.id);
                    if (p.kind == .page) self.pages_changed = true;
                    if (mode != .replay and p.kind != .page) try self.markLayout(p.id);
                }
                self.instances_ok = false;
            },
            .move => {
                const n = self.node(c.node) orelse return error.NoSuchNode;
                const old_pid = self.parents.get(n.id) orelse return error.NoSuchNode;
                if (old_pid.len == 0 or c.parent.len == 0) return error.BadChange;
                const op = self.node(old_pid) orelse return error.NoSuchParent;
                const np = self.node(c.parent) orelse return error.NoSuchParent;
                // Never into itself.
                var up: ?[]const u8 = np.id;
                while (up) |u| {
                    if (std.mem.eql(u8, u, n.id)) return error.Cycle;
                    const pp = self.parents.get(u) orelse break;
                    up = if (pp.len == 0) null else pp;
                }
                page = self.pageOf(np.id);
                const old_page = self.pageOf(op.id);
                const old_at = indexIn(op, n.id) orelse return error.NoSuchNode;
                inv = .{
                    .op = .move,
                    .node = n.id,
                    .parent = op.id,
                    .index = @intCast(old_at),
                };
                try self.addDamage(old_page, self.paintedRect(n));
                const moved = n.*;
                const kept_id = n.id;
                try self.setChildren(op, try removeAt(self.arena.allocator(), op.children, old_at));
                try self.touchTree(op.id);
                const np2 = self.node(c.parent) orelse return error.NoSuchParent;
                const at = @min(c.index, np2.children.len);
                try self.setChildren(np2, try insertAt(self.arena.allocator(), np2.children, at, moved));
                try self.parents.put(self.gpa, kept_id, np2.id);
                const now = &np2.children[at];
                try self.sess.renderer.nodes.put(self.gpa, now.id, now);
                try self.touch(now);
                try self.addDamage(page, self.paintedRect(now));
                self.markDirty(old_page);
                if (op.kind == .page or np2.kind == .page) self.pages_changed = true;
                self.instances_ok = false;
                // Elsewhere, other modes may hold.
                if (mode != .replay and !self.resolving and d.variables.len > 0) try self.markVars(&self.var_trees, now.id);
                if (mode != .replay) {
                    if (op.kind != .page) try self.markLayout(op.id);
                    try self.markLayout(now.id);
                    if (np2.kind != .page) try self.markLayout(np2.id);
                }
            },
            .style => {
                inv = .{
                    .op = .style,
                    .node = c.node,
                    .json = try self.setStyle(c.node, c.json),
                };
            },
            .variable => {
                inv = try self.setVariable(c);
                if (mode != .replay) try self.vars_changed.append(self.gpa, try self.call.allocator().dupe(u8, c.node));
            },
            .collection => {
                inv = try self.setCollection(c);
                if (mode != .replay) self.vars_all = true;
            },
        }
        self.markDirty(page);
        if (c.op == .style or (c.op == .set and c.node.len == 0)) {
            // Document-level: every page's file names it in document.json.
        }
        try self.emit(c);
        if (mode == .user or mode == .derived) try self.record(c, inv, mode == .derived);
    }

    /// Adds `c` to what goes out to other engines.
    fn emit(self: *Editor, c: Change) !void {
        const a = self.out_arena.allocator();
        const page = self.pageForChange(c);
        var edits: u64 = 0;
        if (page) |p| {
            const pg = &(try self.doc()).pages[p];
            pg.edits += 1;
            edits = pg.edits;
        }
        try self.out.append(self.gpa, .{
            .page = if (page) |p| @intCast(p) else -1,
            .edits = edits,
            .json = try c.toJson(a),
        });
    }

    fn indexIn(p: *const m.Node, id: []const u8) ?usize {
        for (p.children, 0..) |c, i| if (std.mem.eql(u8, c.id, id)) return i;
        return null;
    }

    fn insertAt(a: Allocator, list: []m.Node, at: usize, n: m.Node) ![]m.Node {
        const out = try a.alloc(m.Node, list.len + 1);
        @memcpy(out[0..at], list[0..at]);
        out[at] = n;
        @memcpy(out[at + 1 ..], list[at..]);
        return out;
    }

    fn removeAt(a: Allocator, list: []m.Node, at: usize) ![]m.Node {
        const out = try a.alloc(m.Node, list.len - 1);
        @memcpy(out[0..at], list[0..at]);
        @memcpy(out[at..], list[at + 1 ..]);
        return out;
    }

    /// Gives `p` a new list of children: their old places are forgotten and the node
    /// index points at the new ones.
    fn setChildren(self: *Editor, p: *m.Node, list: []m.Node) !void {
        for (p.children) |*c| try self.forgotten.append(self.gpa, @intFromPtr(c));
        p.children = list;
        for (p.children) |*c| try self.sess.renderer.nodes.put(self.gpa, c.id, c);
    }

    fn indexNodes(self: *Editor, n: *const m.Node) !void {
        try self.sess.renderer.nodes.put(self.gpa, n.id, n);
        for (n.children) |*c| try self.indexNodes(c);
    }

    fn unindexNodes(self: *Editor, n: *const m.Node) !void {
        for (n.children) |*c| try self.unindexNodes(c);
        _ = self.sess.renderer.nodes.remove(n.id);
    }

    /// Everything kept of a subtree about to go is stale.
    fn forgetTree(self: *Editor, n: *const m.Node) void {
        self.forgotten.append(self.gpa, @intFromPtr(n)) catch {};
        for (n.children) |*c| self.forgetTree(c);
    }

    /// `file`: the page comes back unloaded, its nodes still in that file ("" : a page
    /// with its nodes, to be written).
    fn insertPage(self: *Editor, page: m.Node, index: u32, file: []const u8) !void {
        const d = try self.doc();
        if (page.kind != .page) return error.NotAPage;
        const at = @min(index, d.pages.len);
        const stored = file.len > 0 and d.chunks.len > 0;
        for (d.pages) |*pg| try self.forgotten.append(self.gpa, @intFromPtr(pg));
        d.pages = try insertAt(self.arena.allocator(), d.pages, at, page);
        if (d.chunks.len > 0) {
            const chunk: m.PageChunk = .{
                .src = if (stored) try self.arena.allocator().dupe(u8, file) else try pages_mod.fileName(self.arena.allocator(), page.id),
            };
            d.chunks = try insertChunk(self.arena.allocator(), d.chunks, at, chunk);
        }
        try self.sess.insertPageSlot(at, !stored);
        try self.dirty.insert(self.gpa, at, !stored);
        try self.kept.insert(self.gpa, at, !stored);
        self.sess.renderer.nodes.clearRetainingCapacity();
        try self.sess.renderer.indexDocument(d);
        try self.indexTree(&d.pages[at], "");
    }

    fn removePage(self: *Editor, at: usize) !void {
        const d = try self.doc();
        if (d.pages.len <= 1) return error.LastPage;
        self.forgetTree(&d.pages[at]);
        self.unindexTree(&d.pages[at]);
        for (d.pages) |*pg| try self.forgotten.append(self.gpa, @intFromPtr(pg));
        d.pages = try removeAt(self.arena.allocator(), d.pages, at);
        if (d.chunks.len > 0) d.chunks = try removeChunk(self.arena.allocator(), d.chunks, at);
        self.sess.removePageSlot(at);
        _ = self.dirty.orderedRemove(at);
        _ = self.kept.orderedRemove(at);
        self.sess.renderer.nodes.clearRetainingCapacity();
        try self.sess.renderer.indexDocument(d);
    }

    fn insertChunk(a: Allocator, list: []m.PageChunk, at: usize, c: m.PageChunk) ![]m.PageChunk {
        const out = try a.alloc(m.PageChunk, list.len + 1);
        @memcpy(out[0..at], list[0..at]);
        out[at] = c;
        @memcpy(out[at + 1 ..], list[at..]);
        return out;
    }

    fn removeChunk(a: Allocator, list: []m.PageChunk, at: usize) ![]m.PageChunk {
        const out = try a.alloc(m.PageChunk, list.len - 1);
        @memcpy(out[0..at], list[0..at]);
        @memcpy(out[at..], list[at + 1 ..]);
        return out;
    }

    /// Sets style `id` from JSON (`null` removes it); answers what was there.
    fn setStyle(self: *Editor, id: []const u8, json: []const u8) ![]const u8 {
        const d = try self.doc();
        const a = self.call.allocator();
        const ea = self.arena.allocator();
        var old: []const u8 = "null";
        var at: ?usize = null;
        for (d.styles, 0..) |st, i| if (std.mem.eql(u8, st.id, id)) {
            at = i;
            var out: std.Io.Writer.Allocating = .init(a);
            var s: Stringify = .{
                .writer = &out.writer,
            };
            try s.beginObject();
            try s.objectField("type");
            try s.write(@tagName(st.kind));
            try s.objectField("name");
            try s.write(st.name);
            if (st.description.len > 0) {
                try s.objectField("description");
                try s.write(st.description);
            }
            if (st.value) |val| {
                try s.objectField("value");
                try s.beginWriteRaw();
                try s.writer.writeAll(val);
                s.endWriteRaw();
            }
            try s.endObject();
            old = out.written();
        };
        const v = try read.parseValue(a, json);
        var list: std.ArrayList(m.Style) = .empty;
        try list.appendSlice(ea, d.styles);
        if (v == .null) {
            if (at) |i| _ = list.orderedRemove(i);
        } else {
            const st: m.Style = .{
                .id = try ea.dupe(u8, id),
                .kind = std.meta.stringToEnum(m.StyleKind, jv.str(v, "type") orelse "fill") orelse .fill,
                .name = try ea.dupe(u8, jv.str(v, "name") orelse ""),
                .description = try ea.dupe(u8, jv.str(v, "description") orelse ""),
                .value = if (jv.get(v, "value")) |val| try Stringify.valueAlloc(ea, val, .{}) else null,
            };
            if (at) |i| list.items[i] = st else try list.append(ea, st);
        }
        d.styles = list.items;
        return old;
    }

    // ------------------------------------------------------------------ variables

    /// Sets variable `c.node` from `c.json` (`null` removes it), at `c.index` in the
    /// document's list when given; answers the change that puts back what was there.
    fn setVariable(self: *Editor, c: Change) !Change {
        const d = try self.doc();
        const a = self.call.allocator();
        const ea = self.arena.allocator();
        var old: []const u8 = "null";
        var at: ?usize = null;
        for (d.variables, 0..) |*v, i| if (std.mem.eql(u8, v.id, c.node)) {
            at = i;
            old = try bodyOf(a, try write.variableJson(a, v));
        };
        const v = try read.parseValue(a, c.json);
        var list: std.ArrayList(m.Variable) = .empty;
        try list.appendSlice(ea, d.variables);
        if (at) |i| _ = list.orderedRemove(i);
        if (v != .null) {
            if (v != .object) return error.BadChange;
            const nv = try m.deepCopy(ea, try read.variableOf(a, c.node, v));
            const to = if (c.index != Change.end) @min(c.index, list.items.len) else at orelse list.items.len;
            try list.insert(ea, @min(to, list.items.len), nv);
        }
        d.variables = list.items;
        return .{
            .op = .variable,
            .node = c.node,
            .json = old,
            .index = if (at) |i| @intCast(i) else Change.end,
        };
    }

    /// `setVariable` for a collection.
    fn setCollection(self: *Editor, c: Change) !Change {
        const d = try self.doc();
        const a = self.call.allocator();
        const ea = self.arena.allocator();
        var old: []const u8 = "null";
        var at: ?usize = null;
        for (d.collections, 0..) |*col, i| if (std.mem.eql(u8, col.id, c.node)) {
            at = i;
            old = try bodyOf(a, try write.collectionJson(a, col));
        };
        const v = try read.parseValue(a, c.json);
        var list: std.ArrayList(m.Collection) = .empty;
        try list.appendSlice(ea, d.collections);
        if (at) |i| _ = list.orderedRemove(i);
        if (v != .null) {
            if (v != .object) return error.BadChange;
            const nc = try m.deepCopy(ea, try read.collectionOf(a, c.node, v));
            const to = if (c.index != Change.end) @min(c.index, list.items.len) else at orelse list.items.len;
            try list.insert(ea, @min(to, list.items.len), nc);
        }
        d.collections = list.items;
        return .{
            .op = .collection,
            .node = c.node,
            .json = old,
            .index = if (at) |i| @intCast(i) else Change.end,
        };
    }

    /// A variable's or collection's JSON without its `id` (as a change carries it).
    fn bodyOf(a: Allocator, json: []const u8) ![]const u8 {
        var v = try read.parseValue(a, json);
        if (v == .object) _ = v.object.orderedRemove("id");
        return Stringify.valueAlloc(a, v, .{});
    }

    fn markVars(self: *Editor, list: *std.ArrayList([]const u8), id: []const u8) !void {
        try list.append(self.gpa, try self.call.allocator().dupe(u8, id));
    }

    fn clearVarMarks(self: *Editor) void {
        self.var_nodes.clearRetainingCapacity();
        self.var_trees.clearRetainingCapacity();
        self.vars_changed.clearRetainingCapacity();
        self.vars_all = false;
    }

    /// After an undo or redo that changed variables: what it did not record (pages read
    /// since the step was made) follows the variables again.
    fn syncVars(self: *Editor, s: *const Step) !void {
        for (s.entries.items) |e| if (e.fwd.op == .variable or e.fwd.op == .collection) {
            self.vars_all = true;
            break;
        };
        if (!self.vars_all) return;
        try self.resolveVars(.sync);
        try self.flush();
    }

    /// Sets the bound fields of what the call reached to their variables' values in the
    /// modes each node is in, as changes of their own (`mode`), so undo replays them:
    /// every node on a loaded page that uses a variable the call changed (or one that
    /// aliases it), the nodes the call changed that have bindings, and everything under
    /// a node whose mode was set or that moved.
    fn resolveVars(self: *Editor, mode: Mode) !void {
        if (self.var_nodes.items.len == 0 and self.var_trees.items.len == 0 and self.vars_changed.items.len == 0 and !self.vars_all) return;
        defer self.clearVarMarks();
        const d = try self.doc();
        if (d.variables.len == 0) return;
        var ix = try pubd_vars.Index.init(self.gpa, d);
        defer ix.deinit(self.gpa);
        self.resolving = true;
        defer self.resolving = false;
        var r: Resolve = .{
            .ed = self,
            .ix = &ix,
            .scratch = .init(self.gpa),
            .mode = mode,
        };
        defer r.deinit();
        if (self.vars_all or self.vars_changed.items.len > 0) {
            var set: std.StringHashMapUnmanaged(void) = .empty;
            defer set.deinit(self.gpa);
            if (self.vars_all) {
                for (d.variables) |v| try set.put(self.gpa, v.id, {});
            } else {
                var deps = try ix.dependents(self.gpa, self.vars_changed.items);
                defer deps.deinit(self.gpa);
                var it = deps.keyIterator();
                while (it.next()) |k| try set.put(self.gpa, k.*, {});
            }
            r.uses = &set;
            r.scale = 1;
            r.stack.clearRetainingCapacity();
            for (0..d.pages.len) |i| {
                if (!self.sess.pageLoaded(i)) continue;
                try r.tree(&self.doc_pages()[i], true);
            }
            r.uses = null;
            try self.restyle(&ix, &set, mode);
        }
        const a = self.call.allocator();
        for (self.var_trees.items) |id| {
            const n = self.node(id) orelse continue;
            try r.at(a, id);
            try r.tree(n, false);
        }
        for (self.var_nodes.items) |id| {
            const n = self.node(id) orelse continue;
            try r.at(a, id);
            try r.one(n);
        }
        // Component properties that follow variables: set as the instance's property.
        for (r.props.items) |pu| {
            const val = try read.parseValue(a, pu.value);
            try self.setProperty(pu.node, pu.prop, val);
        }
    }

    /// Shared styles whose value follows a variable in `set` take its value in the
    /// default modes (a style belongs to no frame), as `style` changes of their own.
    fn restyle(self: *Editor, ix: *const pubd_vars.Index, set: *const std.StringHashMapUnmanaged(void), mode: Mode) !void {
        const d = try self.doc();
        const a = self.call.allocator();
        var scratch: std.heap.ArenaAllocator = .init(self.gpa);
        defer scratch.deinit();
        var changes: std.ArrayList(Change) = .empty;
        for (d.styles) |st| {
            const val = st.value orelse continue;
            if (std.mem.indexOf(u8, val, "\"var") == null) continue;
            // The value as a probe node's field, resolved there.
            const key: []const u8 = switch (st.kind) {
                .fill => "fills",
                .effect => "effects",
                .grid => "grids",
                .text => "style",
            };
            const kind: []const u8 = if (st.kind == .text) "text" else "frame";
            const probe_json = try std.fmt.allocPrint(a, "{{\"id\":\"s\",\"type\":\"{s}\",\"{s}\":{s}}}", .{ kind, key, val });
            var probe = read.nodeFromJson(self.gpa, a, probe_json, .{}) catch continue;
            if (!pubd_vars.usesAny(ix, &probe, set)) continue;
            _ = scratch.reset(.retain_capacity);
            const ch = try pubd_vars.applyNode(ix, scratch.allocator(), a, &probe, &.{});
            if (!ch.any()) continue;
            const out = try read.parseValue(a, try props.values(a, &probe, &.{key}));
            const new_val = try Stringify.valueAlloc(a, out.object.get(key).?, .{});
            var body: std.Io.Writer.Allocating = .init(a);
            var w: Stringify = .{
                .writer = &body.writer,
            };
            try w.beginObject();
            try w.objectField("type");
            try w.write(@tagName(st.kind));
            try w.objectField("name");
            try w.write(st.name);
            if (st.description.len > 0) {
                try w.objectField("description");
                try w.write(st.description);
            }
            try w.objectField("value");
            try w.beginWriteRaw();
            try w.writer.writeAll(new_val);
            w.endWriteRaw();
            try w.endObject();
            try changes.append(a, .{
                .op = .style,
                .node = st.id,
                .json = body.written(),
            });
        }
        // Applied after the walk: a style change replaces the list walked.
        for (changes.items) |c| try self.prim(c, mode);
    }

    fn doc_pages(self: *Editor) []m.Node {
        return (self.doc() catch unreachable).pages;
    }

    const PropUpdate = struct {
        node: []const u8,
        prop: []const u8,
        value: []const u8,
    };

    /// One resolution pass.
    const Resolve = struct {
        ed: *Editor,
        ix: *const pubd_vars.Index,
        scratch: std.heap.ArenaAllocator,
        mode: Mode,
        /// The modes in force (innermost last).
        stack: std.ArrayList(m.ModeChoice) = .empty,
        /// The scale of the instances scaled as a whole the walk is in.
        scale: f32 = 1,
        /// Only nodes using one of these (when set).
        uses: ?*const std.StringHashMapUnmanaged(void) = null,
        props: std.ArrayList(PropUpdate) = .empty,

        fn deinit(r: *Resolve) void {
            r.stack.deinit(r.ed.gpa);
            r.props.deinit(r.ed.gpa);
            r.scratch.deinit();
        }

        /// The modes in force above node `id` (its own are pushed when it is visited).
        fn at(r: *Resolve, a: Allocator, id: []const u8) !void {
            r.stack.clearRetainingCapacity();
            r.scale = 1;
            const path = r.ed.pathTo(a, id) catch return;
            for (path[0 .. path.len - 1]) |p| try r.stack.appendSlice(r.ed.gpa, p.modes);
            r.scale = pubd_vars.scaleAlong(path[0 .. path.len - 1]);
        }

        fn tree(r: *Resolve, n: *m.Node, root_page: bool) anyerror!void {
            _ = root_page;
            const before = r.stack.items.len;
            defer r.stack.shrinkRetainingCapacity(before);
            const outer = r.scale;
            defer r.scale = outer;
            r.scale = pubd_vars.scaleOf(n, outer);
            try r.stack.appendSlice(r.ed.gpa, n.modes);
            try r.resolve(n);
            // Children stay where they are: the changes set fields only.
            for (n.children) |*c| try r.tree(c, false);
        }

        fn one(r: *Resolve, n: *m.Node) !void {
            r.scale = pubd_vars.scaleOf(n, r.scale);
            try r.stack.appendSlice(r.ed.gpa, n.modes);
            try r.resolve(n);
        }

        fn resolve(r: *Resolve, n: *m.Node) !void {
            if (!pubd_vars.hasBindings(n)) return;
            if (r.uses) |set| if (!pubd_vars.usesAny(r.ix, n, set)) return;
            const ed = r.ed;
            const a = ed.call.allocator();
            _ = r.scratch.reset(.retain_capacity);
            const sa = r.scratch.allocator();
            var copy = n.*;
            const ch = try pubd_vars.applyNodeAt(r.ix, sa, a, &copy, r.stack.items, r.scale);
            for (n.vars) |b| {
                if (!std.mem.startsWith(u8, b.key, "props/")) continue;
                const prop = b.key["props/".len..];
                const val = r.ix.resolve(sa, b.variable, r.stack.items) orelse continue;
                const json = switch (val) {
                    .boolean, .string => try pubd_vars.resolvedJson(a, val),
                    else => continue,
                };
                var same = false;
                for (n.props) |p| if (std.mem.eql(u8, p.id, prop)) {
                    same = std.mem.eql(u8, p.value, json);
                };
                if (!same) try r.props.append(ed.gpa, .{
                    .node = n.id,
                    .prop = try a.dupe(u8, prop),
                    .value = json,
                });
            }
            if (!ch.any()) return;
            var buf: [pubd_vars.node_keys.len][]const u8 = undefined;
            const json = try props.values(a, &copy, ch.list(&buf));
            ed.paint_only = ch.paintOnly();
            defer ed.paint_only = false;
            try ed.prim(.{
                .op = .set,
                .node = n.id,
                .json = json,
            }, r.mode);
        }
    };

    /// A set that gives a bound field a value its variable does not detaches the
    /// variable (as typing a value into a bound field does in Figma): the set takes the
    /// binding lists without it. A set that names `vars` says itself what follows what.
    fn detachStale(self: *Editor, a: Allocator, n: *const m.Node, v: *Value) !void {
        const d = try self.doc();
        if (d.variables.len == 0 or !pubd_vars.hasBindings(n)) return;
        if (v.object.get("vars") != null) return;
        var names: std.ArrayList([]const u8) = .empty;
        var it = v.object.iterator();
        while (it.next()) |e| try names.append(a, e.key_ptr.*);
        var copy = n.*;
        try props.apply(self.gpa, a, &copy, v.object);
        var ix = try pubd_vars.Index.init(self.gpa, d);
        defer ix.deinit(self.gpa);
        var scratch: std.heap.ArenaAllocator = .init(self.gpa);
        defer scratch.deinit();
        const path = try self.pathTo(a, n.id);
        const modes = try pubd_vars.modesAlong(a, path);
        const pr = try pubd_vars.pruneStale(&ix, scratch.allocator(), a, &copy, modes, pubd_vars.scaleAlong(path), names.items);
        if (!pr.any()) return;
        var keys: std.ArrayList([]const u8) = .empty;
        if (pr.vars) try keys.append(a, "vars");
        if (pr.fills) try keys.append(a, "fills");
        if (pr.strokes) try keys.append(a, "strokes");
        if (pr.effects) try keys.append(a, "effects");
        if (pr.grids) try keys.append(a, "grids");
        if (pr.style) try keys.append(a, "style");
        if (pr.runs) try keys.append(a, "runs");
        const vals = try read.parseValue(a, try props.values(a, &copy, keys.items));
        for (keys.items) |k| try v.object.put(a, k, vals.object.get(k).?);
    }

    // ------------------------------------------------------------------ replicas

    /// Applies changes another engine made (`takeOut`'s `changes`), as they are: nothing
    /// recorded, nothing laid out or set off. For engines that hold the same document.
    pub fn replay(self: *Editor, json: []const u8) !void {
        try self.ensureIndex();
        self.beginCall();
        defer self.endCall();
        const a = self.call.allocator();
        const v = try read.parseValue(a, json);
        const list = if (v == .array) v.array.items else &[_]Value{v};
        for (list) |item| {
            const cv = jv.get(item, "change") orelse item;
            const c = try Change.fromValue(a, cv);
            try self.prim(c, .replay);
        }
    }

    /// What the calls since the last `takeOut` did, as JSON:
    /// `{"changes":[{"page":p,"edits":n,"change":{...}}],"damage":[[page,x0,y0,x1,y1]],"pages":bool,
    /// "undo":bool,"redo":bool,"history":bytes}`. Clears it.
    pub fn takeOut(self: *Editor, gpa: Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        var s: Stringify = .{
            .writer = &out.writer,
        };
        try s.beginObject();
        try s.objectField("changes");
        try s.beginArray();
        for (self.out.items) |o| {
            try s.beginObject();
            try s.objectField("page");
            try s.write(o.page);
            try s.objectField("edits");
            try s.write(o.edits);
            try s.objectField("change");
            try s.beginWriteRaw();
            try s.writer.writeAll(o.json);
            s.endWriteRaw();
            try s.endObject();
        }
        try s.endArray();
        try s.objectField("damage");
        try s.beginArray();
        for (self.damage.items) |dm| {
            if (!(std.math.isFinite(dm.rect.x0) and std.math.isFinite(dm.rect.y0) and std.math.isFinite(dm.rect.x1) and std.math.isFinite(dm.rect.y1))) continue;
            try s.write([5]f32{ @floatFromInt(dm.page), dm.rect.x0, dm.rect.y0, dm.rect.x1, dm.rect.y1 });
        }
        try s.endArray();
        try s.objectField("pages");
        try s.write(self.pages_changed);
        try s.objectField("undo");
        try s.write(self.canUndo());
        try s.objectField("redo");
        try s.write(self.canRedo());
        try s.objectField("history");
        try s.write(self.historyBytes());
        try s.endObject();
        self.out.clearRetainingCapacity();
        _ = self.out_arena.reset(.retain_capacity);
        self.damage.clearRetainingCapacity();
        self.pages_changed = false;
        return out.toOwnedSlice();
    }

    /// Takes the node pointers whose kept data is stale (`forgotten`, then the subtrees
    /// in `forgotten_trees`): the GPU scene drops what it keeps of them.
    pub fn takeForgotten(self: *Editor) struct {
        nodes: []const usize,
        trees: []const usize,
    } {
        return .{
            .nodes = self.forgotten.items,
            .trees = self.forgotten_trees.items,
        };
    }

    pub fn clearForgotten(self: *Editor) void {
        self.forgotten.clearRetainingCapacity();
        self.forgotten_trees.clearRetainingCapacity();
    }

    // ------------------------------------------------------------------ reading

    /// Node `id` for a properties panel, as JSON: its own Pubd fields (`node`), where it
    /// is (`parent`, `index`, `page`, `children`), its box on the page, and for an
    /// instance or a layer inside one, the instance, its path there, what it overrides and
    /// the main's node it copies.
    pub fn nodeInfo(self: *Editor, gpa: Allocator, id: []const u8) ![]u8 {
        try self.ensureIndex();
        const n = self.node(id) orelse return error.NoSuchNode;
        var tmp: std.heap.ArenaAllocator = .init(gpa);
        defer tmp.deinit();
        const a = tmp.allocator();
        const own = try write.nodeJson(a, n, .{
            .children = false,
        });
        var out: std.Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        var s: Stringify = .{
            .writer = &out.writer,
        };
        try s.beginObject();
        try s.objectField("node");
        try s.beginWriteRaw();
        try s.writer.writeAll(own);
        s.endWriteRaw();
        const pid = self.parents.get(id) orelse "";
        try s.objectField("parent");
        try s.write(pid);
        try s.objectField("index");
        if (self.node(pid)) |p| try s.write(indexIn(p, id)) else try s.write(self.pageIndexById(id));
        try s.objectField("page");
        try s.write(self.pageOf(id));
        try s.objectField("children");
        try s.write(n.children.len);
        const ctm = self.pageCtm(id);
        const box = geom.Rect.transformed(.{
            .x1 = n.size.x,
            .y1 = n.size.y,
        }, ctm);
        try s.objectField("box");
        try s.write([4]f32{ box.x0, box.y0, box.x1, box.y1 });
        if (try self.ownerOf(a, n)) |o| {
            try s.objectField("instance");
            try s.beginObject();
            try s.objectField("id");
            try s.write(o.inst.id);
            try s.objectField("path");
            try s.write(o.path);
            try s.objectField("overrides");
            try s.write(if (o.inst.overrides == null) null else overridesAt(o.inst, o.path));
            if (o.inst.component) |cid| if (self.node(cid)) |main| {
                if (try self.mainNode(a, main, o.path)) |r| {
                    try s.objectField("main");
                    try s.write(r.id);
                }
            };
            try s.endObject();
        }
        if (self.mainOf(n)) |main| {
            try s.objectField("component");
            try s.write(main.id);
        }
        try s.endObject();
        return out.toOwnedSlice();
    }

    // ------------------------------------------------------------------ variables, read

    /// The document's collections and variables, as `document.json` keeps them but as
    /// lists in order, each with its `id`:
    /// `{"collections":[{"id",...}],"variables":[{"id",...}]}`.
    pub fn variablesJson(self: *Editor, gpa: Allocator) ![]u8 {
        const d = try self.doc();
        var tmp: std.heap.ArenaAllocator = .init(gpa);
        defer tmp.deinit();
        const a = tmp.allocator();
        var out: std.Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        try out.writer.writeAll("{\"collections\":[");
        for (d.collections, 0..) |*c, i| {
            if (i > 0) try out.writer.writeByte(',');
            try out.writer.writeAll(try write.collectionJson(a, c));
        }
        try out.writer.writeAll("],\"variables\":[");
        for (d.variables, 0..) |*v, i| {
            if (i > 0) try out.writer.writeByte(',');
            try out.writer.writeAll(try write.variableJson(a, v));
        }
        try out.writer.writeAll("]}");
        return out.toOwnedSlice();
    }

    /// What variable `ref` is worth at node `id` (in the modes it is in; "" the
    /// document, every collection in its default mode): `{"value": <Pubd JSON> | null}`.
    /// A composed colour is `{"color": C, "opacity": o}`.
    pub fn variableValue(self: *Editor, gpa: Allocator, id: []const u8, ref: []const u8) ![]u8 {
        const d = try self.doc();
        var tmp: std.heap.ArenaAllocator = .init(gpa);
        defer tmp.deinit();
        const a = tmp.allocator();
        const modes = try self.modesFor(a, id);
        var ix = try pubd_vars.Index.init(gpa, d);
        defer ix.deinit(gpa);
        const r = ix.resolve(a, ref, modes);
        const val = if (r) |x| try pubd_vars.resolvedJson(a, x) else "null";
        return std.fmt.allocPrint(gpa, "{{\"value\":{s}}}", .{val});
    }

    /// Every variable of collection `col` worth in each of its modes, aliases followed
    /// (an alias into another collection in that one's default mode), as the variables
    /// window's table shows them: `{"<variable id>":[<value> | null, ...]}`, a value per
    /// mode in the collection's order. An extended collection lists its parent's
    /// variables in its own modes (its overrides in force). `col` empty: every variable,
    /// each in the default modes (one value).
    pub fn variableTable(self: *Editor, gpa: Allocator, col: []const u8) ![]u8 {
        const d = try self.doc();
        var tmp: std.heap.ArenaAllocator = .init(gpa);
        defer tmp.deinit();
        const a = tmp.allocator();
        var ix = try pubd_vars.Index.init(gpa, d);
        defer ix.deinit(gpa);
        const c: ?*const m.Collection = if (col.len == 0) null else ix.cols.get(col) orelse return error.NoSuchCollection;
        // The variables shown: the collection's own, or its parent's when it extends one.
        const owner: []const u8 = if (c) |x| x.parent orelse x.id else "";
        var out: std.Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        var s: Stringify = .{
            .writer = &out.writer,
        };
        try s.beginObject();
        for (d.variables) |*v| {
            if (c != null and !std.mem.eql(u8, v.collection, owner)) continue;
            try s.objectField(v.id);
            try s.beginArray();
            if (c) |x| {
                for (x.modes) |md| {
                    const choice = [_]m.ModeChoice{.{
                        .collection = x.id,
                        .mode = md.id,
                    }};
                    try writeResolved(&s, a, ix.resolve(a, v.id, &choice));
                }
            } else try writeResolved(&s, a, ix.resolve(a, v.id, &.{}));
            try s.endArray();
        }
        try s.endObject();
        return out.toOwnedSlice();
    }

    fn writeResolved(s: *Stringify, a: Allocator, r: ?pubd_vars.Resolved) !void {
        if (r) |x| {
            try s.beginWriteRaw();
            try s.writer.writeAll(try pubd_vars.resolvedJson(a, x));
            s.endWriteRaw();
        } else try s.write(null);
    }

    /// The mode each collection is in at node `id`: `[{"collection","mode","set":id?}]`,
    /// `set` the node that chose it (absent: the collection's default).
    pub fn modesAt(self: *Editor, gpa: Allocator, id: []const u8) ![]u8 {
        const d = try self.doc();
        var tmp: std.heap.ArenaAllocator = .init(gpa);
        defer tmp.deinit();
        const a = tmp.allocator();
        try self.ensureIndex();
        const path: []*m.Node = if (id.len == 0) &.{} else try self.pathTo(a, id);
        var ix = try pubd_vars.Index.init(gpa, d);
        defer ix.deinit(gpa);
        const modes = try pubd_vars.modesAlong(a, path);
        var out: std.Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        var s: Stringify = .{
            .writer = &out.writer,
        };
        try s.beginArray();
        for (d.collections) |*c| {
            const pick = ix.modeOf(c, modes);
            try s.beginObject();
            try s.objectField("collection");
            try s.write(c.id);
            try s.objectField("mode");
            try s.write(if (pick.ext != null) pick.ext_mode else pick.mode);
            // The innermost node that chose it.
            var k = path.len;
            while (k > 0) {
                k -= 1;
                var chose = false;
                for (path[k].modes) |mc| chose = chose or std.mem.eql(u8, mc.collection, c.id) or (if (pick.ext) |e| std.mem.eql(u8, mc.collection, e.id) else false);
                if (chose) {
                    try s.objectField("set");
                    try s.write(path[k].id);
                    break;
                }
            }
            try s.endObject();
        }
        try s.endArray();
        return out.toOwnedSlice();
    }

    fn modesFor(self: *Editor, a: Allocator, id: []const u8) ![]m.ModeChoice {
        if (id.len == 0) return &.{};
        try self.ensureIndex();
        return pubd_vars.modesAlong(a, try self.pathTo(a, id));
    }

    // ------------------------------------------------------------------ saving

    /// `document.json` for the document kept page by page (a document in one file is
    /// split now): every page's own fields with its file and its frames.
    pub fn documentJson(self: *Editor, gpa: Allocator) ![]u8 {
        const d = try self.doc();
        const ea = self.arena.allocator();
        if (d.chunks.len != d.pages.len) {
            const chunks = try ea.alloc(m.PageChunk, d.pages.len);
            for (d.pages, chunks) |*pg, *c| c.* = try pages_mod.chunkOf(ea, pg);
            d.chunks = chunks;
            // Pages in the document are loaded: each takes a slot of its own.
            try self.sess.splitPages();
        } else for (d.pages, 0..) |*pg, i| {
            if (!self.sess.pageLoaded(i)) continue;
            const src = d.chunks[i].src;
            d.chunks[i] = try pages_mod.chunkOf(ea, pg);
            if (src.len > 0) d.chunks[i].src = src;
        }
        d.components = try self.componentIndex(ea);
        // Fonts the changed pages ask for.
        var fonts: std.ArrayList(m.FontRef) = .empty;
        try fonts.appendSlice(ea, d.fonts);
        for (d.pages, 0..) |*pg, i| if (self.isDirty(i)) try m.collectFonts(ea, pg, &fonts);
        d.fonts = fonts.items;
        return write.toJson(gpa, d);
    }

    /// The document's components as they are now: a loaded page's read from its nodes,
    /// the others' as the file lists them.
    fn componentIndex(self: *Editor, a: Allocator) ![]m.ComponentRef {
        const d = try self.doc();
        var out: std.ArrayList(m.ComponentRef) = .empty;
        for (d.pages, 0..) |*pg, i| {
            if (self.sess.pageLoaded(i)) {
                try pages_mod.componentsOf(a, pg, &out);
            } else for (d.components) |c| {
                if (std.mem.eql(u8, c.page, pg.id)) try out.append(a, c);
            }
        }
        return out.items;
    }

    /// Component or component set `id` as `document.json`'s `components` lists it
    /// (`{ "type", "name", "page", "set"?, "properties"? }`), read from its node when its
    /// page is loaded; `null` when the document has no such component.
    pub fn componentJson(self: *Editor, gpa: Allocator, id: []const u8) ![]u8 {
        try self.ensureIndex();
        const d = try self.doc();
        var found: ?m.ComponentRef = null;
        if (self.node(id)) |n| {
            if (n.kind == .component or n.kind == .component_set) {
                const pi = self.pageOf(id);
                const set = if (self.parentOf(id)) |p| (if (p.kind == .component_set) p.id else "") else "";
                found = .{
                    .id = n.id,
                    .name = n.name,
                    .kind = n.kind,
                    .page = if (pi) |i| d.pages[i].id else "",
                    .set = set,
                    .properties = n.properties,
                };
            }
        } else for (d.components) |c| {
            if (std.mem.eql(u8, c.id, id)) found = c;
        }
        const c = found orelse return gpa.dupe(u8, "null");
        var out: std.Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        var s: Stringify = .{
            .writer = &out.writer,
        };
        try s.beginObject();
        try s.objectField("id");
        try s.write(c.id);
        try s.objectField("type");
        try s.write(if (c.kind == .component_set) "component-set" else "component");
        try s.objectField("name");
        try s.write(c.name);
        try s.objectField("page");
        try s.write(c.page);
        try s.objectField("pageIndex");
        var at: i64 = -1;
        for (d.pages, 0..) |pg, i| if (std.mem.eql(u8, pg.id, c.page)) {
            at = @intCast(i);
        };
        try s.write(at);
        try s.objectField("set");
        try s.write(c.set);
        try s.objectField("properties");
        try s.beginWriteRaw();
        try write.propDefsJson(&out.writer, c.properties);
        s.endWriteRaw();
        try s.endObject();
        return out.toOwnedSlice();
    }

    /// Page `i`'s own file (`pages/<id>.json`).
    pub fn pageJson(self: *Editor, gpa: Allocator, i: usize) ![]u8 {
        const d = try self.doc();
        if (i >= d.pages.len) return error.NoSuchPage;
        if (!self.sess.pageLoaded(i)) return error.PageNotLoaded;
        return write.pageJson(gpa, &d.pages[i]);
    }

    /// The pages are saved: none holds unsaved changes now.
    pub fn saved(self: *Editor) void {
        for (self.dirty.items) |*x| x.* = false;
    }
};

/// Whether a set of these keys may change only paints' colours (the text's runs only
/// when a variable resolves them: their paints, never their styles).
fn colourKeysOnly(names: []const []const u8, paint_only: bool) bool {
    for (names) |k| {
        if (std.mem.eql(u8, k, "fills") or std.mem.eql(u8, k, "strokes")) continue;
        if (paint_only and std.mem.eql(u8, k, "runs")) continue;
        return false;
    }
    return names.len > 0;
}

/// A node's paint lists (as `props.apply` replaces them, the old ones stay readable).
const Paints = struct {
    fills: []const m.Paint,
    strokes: []const m.Paint,
    runs: []const m.Run,

    fn of(n: *const m.Node) Paints {
        return .{
            .fills = n.fills,
            .strokes = n.strokes,
            .runs = if (n.text) |t| t.runs else &.{},
        };
    }

    /// Whether `b` differs from these only in colours (paints' and stops').
    fn sameButColours(a: Paints, b: Paints) bool {
        if (!listSame(a.fills, b.fills) or !listSame(a.strokes, b.strokes)) return false;
        if (a.runs.len != b.runs.len) return false;
        for (a.runs, b.runs) |ra, rb| {
            if (ra.from != rb.from or ra.to != rb.to) return false;
            if ((ra.fills == null) != (rb.fills == null)) return false;
            if (ra.fills) |fa| if (!listSame(fa, rb.fills.?)) return false;
        }
        return true;
    }

    fn listSame(a: []const m.Paint, b: []const m.Paint) bool {
        if (a.len != b.len) return false;
        for (a, b) |pa, pb| if (!paintSame(pa, pb)) return false;
        return true;
    }

    fn paintSame(a: m.Paint, b: m.Paint) bool {
        if (a.kind != b.kind or a.visible != b.visible or a.opacity != b.opacity or a.blend != b.blend) return false;
        if (a.kind != .solid and !(a.kind == .linear or a.kind == .radial or a.kind == .angular or a.kind == .diamond)) return false;
        if (a.stops.len != b.stops.len) return false;
        for (a.stops, b.stops) |sa, sb| if (sa.at != sb.at) return false;
        return std.meta.eql(a.handles, b.handles);
    }
};

/// Whether a set of these keys changes only paints: nothing of the node's shape (its
/// outline, its text's glyphs) follows them.
fn paintKeysOnly(names: []const []const u8) bool {
    const paints = [_][]const u8{ "fills", "strokes", "effects", "opacity", "blend" };
    for (names) |k| {
        for (paints) |p| {
            if (std.mem.eql(u8, k, p)) break;
        } else return false;
    }
    return names.len > 0;
}

test {
    _ = @import("editor_test.zig");
    _ = @import("vars_test.zig");
    _ = @import("tree.zig");
}
