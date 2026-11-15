//! `pe layout-check <doc.pubd> [--show N] [--instances] [--incremental N] [--text]`: the
//! layout oracle.
//!
//! The corpora store Figma's resolved layout. This loads the document twice, sets every
//! size and position that rules decide to NaN in the working copy (so nothing can be read
//! back from the answer), runs `relayout`, and compares every node's translation and size
//! with the stored ones: exact (within 0.01 px), close (within 0.5 px) or wrong, grouped by
//! the rule that decided the value, with the worst offenders of each rule.
//!
//! `--instances` also checks constraints: every instance whose main component is in the
//! document starts as a copy of the component's geometry at the component's size and is
//! then resized to its own size, so constraints and auto layout must move its children to
//! where Figma put them (size overrides in the instance show up as wrong).
//!
//! `--incremental N` edits N texts one at a time and checks `relayoutFrom` agrees with a
//! full `relayout`; `--text` lists auto-sized texts with their natural sizes.

const std = @import("std");
const engine = @import("publr_engine");
const corpus = @import("corpus.zig");

const m = engine.model;
const lay = engine.relayout;
const Io = std.Io;

const exact_tol: f32 = 0.01;
const close_tol: f32 = 0.5;

const Offender = struct {
    id: []const u8,
    name: []const u8,
    err: f32,
    stored: [2]f32,
    got: [2]f32,
};

const Stats = struct {
    count: u32 = 0,
    exact: u32 = 0,
    close: u32 = 0,
    wrong: u32 = 0,
    worst: f32 = 0,
    offenders: std.ArrayList(Offender) = .empty,
};

const Table = std.StringArrayHashMapUnmanaged(Stats);

const Check = struct {
    a: std.mem.Allocator,
    sizes: Table = .empty,
    positions: Table = .empty,
    nodes: u32 = 0,
    /// Values decided by rules (not inputs).
    ruled: u32 = 0,
    exact: u32 = 0,
    close: u32 = 0,
    wrong: u32 = 0,

    fn add(ck: *Check, table: *Table, label: []const u8, ruled: bool, n: *const m.Node, stored: [2]f32, got: [2]f32) !void {
        var err: f32 = 0;
        for (stored, got) |s, g| {
            const d = @abs(s - g);
            err = @max(err, if (std.math.isNan(d)) std.math.inf(f32) else d);
        }
        const e = try table.getOrPut(ck.a, label);
        if (!e.found_existing) e.value_ptr.* = .{};
        const st = e.value_ptr;
        st.count += 1;
        st.worst = @max(st.worst, err);
        if (err <= exact_tol) {
            st.exact += 1;
        } else if (err <= close_tol) {
            st.close += 1;
        } else st.wrong += 1;
        if (ruled) {
            ck.ruled += 1;
            if (err <= exact_tol) {
                ck.exact += 1;
            } else if (err <= close_tol) {
                ck.close += 1;
            } else ck.wrong += 1;
        }
        if (err > exact_tol) try st.offenders.append(ck.a, .{
            .id = n.id,
            .name = n.name,
            .err = err,
            .stored = stored,
            .got = got,
        });
    }
};

pub fn run(io: Io, gpa: std.mem.Allocator, w: *Io.Writer, dir: []const u8, args: []const []const u8) !void {
    var show: usize = 4;
    var instances = false;
    var text = false;
    var edits: usize = 0;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--show") and i + 1 < args.len) {
            show = try std.fmt.parseInt(usize, args[i + 1], 10);
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--instances")) {
            instances = true;
        } else if (std.mem.eql(u8, args[i], "--incremental") and i + 1 < args.len) {
            edits = try std.fmt.parseInt(usize, args[i + 1], 10);
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--text")) text = true;
    }

    var stored = try corpus.load(io, gpa, dir, .{
        .images = false,
    });
    defer stored.deinit(gpa);
    var work = try corpus.load(io, gpa, dir, .{
        .images = false,
    });
    defer work.deinit(gpa);

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var ck: Check = .{
        .a = arena.allocator(),
    };

    if (text) {
        for (stored.doc.pages) |*p| try listText(gpa, w, &stored.fonts, p);
        return;
    }
    for (work.doc.pages) |*p| for (p.children) |*c| garble(p, c);
    const t0 = Io.Timestamp.now(io, .awake);
    const report = try lay.relayout(gpa, &work.doc, .{
        .fonts = &work.fonts,
    });
    const ms: u64 = @intCast(@divTrunc(t0.untilNow(io, .awake).nanoseconds, std.time.ns_per_ms));
    for (stored.doc.pages, work.doc.pages) |*sp, *wp| {
        for (sp.children, wp.children) |*s, *g| try compare(&ck, sp, s, g);
    }
    try w.print("layout-check {s}\n", .{dir});
    try w.print("relayout: {d} nodes placed, {d} auto layouts, {d} text layouts, {d} texts unmeasured, {d} ms\n\n", .{ report.nodes, report.flows, report.texts, report.unmeasured, ms });
    try printTables(w, &ck, show);

    if (edits > 0) try incremental(gpa, w, arena.allocator(), &work, edits);

    if (instances) {
        var inst: Check = .{
            .a = arena.allocator(),
        };
        var work2 = try corpus.load(io, gpa, dir, .{
            .images = false,
        });
        defer work2.deinit(gpa);
        var index: std.StringHashMapUnmanaged(*const m.Node) = .empty;
        for (stored.doc.pages) |*p| try indexNodes(arena.allocator(), &index, p);
        var resets: u32 = 0;
        var scaled: u32 = 0;
        for (work2.doc.pages, stored.doc.pages) |*p, *sp| try resetInstances(gpa, &work2, &index, p, sp, &inst, &resets, &scaled);
        try w.print("\ninstances from their components ({d} instances, {d} scaled ones skipped): constraints and layout\n\n", .{ resets, scaled });
        try printTables(w, &inst, show);
    }
}

/// `--text`: every auto-sized text with its stored size and its natural (unrounded) one.
fn listText(gpa: std.mem.Allocator, w: *Io.Writer, fonts: *const engine.layout.FontSet, n: *const m.Node) !void {
    if (n.text) |t| if (t.resize == .width_and_height or t.resize == .height) {
        const ts = try lay.measureText(gpa, t, if (t.resize == .height) n.size.x else null, fonts);
        const ls: f32 = if (t.style.letter_spacing) |l| switch (l) {
            .px => |v| v,
            .percent => |v| v,
        } else 0;
        const lh: f32 = if (t.style.line_height) |l| switch (l) {
            .px => |v| v,
            .percent => |v| -v,
            .auto => 0,
        } else 0;
        try w.print("{s} {s} {d} {d} {d} {d} {d} {d} {s}|{s}|{d}|ls={d}|lh={d}|runs={d}\n", .{
            @tagName(t.resize),
            n.id,
            n.size.x,
            n.size.y,
            if (ts) |x| x.w else -1,
            if (ts) |x| x.h else -1,
            if (ts) |x| x.lines else 0,
            t.text.len,
            t.style.family orelse "",
            t.style.font_style orelse "",
            t.style.size orelse 0,
            ls,
            lh,
            t.runs.len,
        });
    };
    for (n.children) |*c| try listText(gpa, w, fonts, c);
}

/// `--incremental N`: lengthens N auto-sized texts one at a time, lays out from each with
/// `relayoutFrom`, and checks the document matches a full `relayout` of the same edit.
fn incremental(gpa: std.mem.Allocator, w: *Io.Writer, a: std.mem.Allocator, work: *corpus.Loaded, edits: usize) !void {
    var texts: std.ArrayList(*m.Node) = .empty;
    for (work.doc.pages) |*p| try collectTexts(a, p, &texts);
    if (texts.items.len == 0) return;
    const step = @max(1, texts.items.len / edits);
    var tried: u32 = 0;
    var matched: u32 = 0;
    var moved: u32 = 0;
    var first_bad: ?[]const u8 = null;
    var k: usize = 0;
    while (k < texts.items.len and tried < edits) : (k += step) {
        const t = texts.items[k];
        const before = t.text.?.text;
        t.text.?.text = try std.fmt.allocPrint(a, "{s} Wider", .{before});
        _ = try lay.relayoutFrom(gpa, &work.doc, t.id, .{
            .fonts = &work.fonts,
        });
        const inc = try snapshot(a, &work.doc);
        _ = try lay.relayout(gpa, &work.doc, .{
            .fonts = &work.fonts,
        });
        const full = try snapshot(a, &work.doc);
        var bad: u32 = 0;
        for (inc, full) |x, y| {
            for (x, y) |u, v| if (!(@abs(u - v) <= exact_tol)) {
                bad += 1;
                break;
            };
        }
        // How many nodes the edit moved or resized (against the layout before it).
        t.text.?.text = before;
        _ = try lay.relayout(gpa, &work.doc, .{
            .fonts = &work.fonts,
        });
        const back = try snapshot(a, &work.doc);
        for (full, back) |x, y| {
            for (x, y) |u, v| if (!(@abs(u - v) <= exact_tol)) {
                moved += 1;
                break;
            };
        }
        tried += 1;
        if (bad == 0) matched += 1 else if (first_bad == null) first_bad = t.id;
    }
    try w.print("\nincremental: {d} text edits laid out from the edited node; {d} match a full relayout ({d} node changes in all)", .{ tried, matched, moved });
    if (first_bad) |id| try w.print("; first mismatch after editing {s}", .{id});
    try w.print("\n", .{});
}

fn collectTexts(a: std.mem.Allocator, n: *m.Node, out: *std.ArrayList(*m.Node)) !void {
    if (n.text) |t| if (t.resize == .width_and_height or t.resize == .height) try out.append(a, n);
    for (n.children) |*c| try collectTexts(a, c, out);
}

/// Every node's translation and size, depth first.
fn snapshot(a: std.mem.Allocator, doc: *const m.Document) ![][4]f32 {
    var out: std.ArrayList([4]f32) = .empty;
    for (doc.pages) |*p| try snap(a, p, &out);
    return out.items;
}

fn snap(a: std.mem.Allocator, n: *const m.Node, out: *std.ArrayList([4]f32)) !void {
    try out.append(a, .{ n.transform.e, n.transform.f, n.size.x, n.size.y });
    for (n.children) |*c| try snap(a, c, out);
}

/// Sets what the rules decide to NaN: in-flow positions, and sizes that hug or fill.
fn garble(parent: *const m.Node, n: *m.Node) void {
    const in_flow = lay.inFlow(parent, n);
    const nan = std.math.nan(f32);
    if (in_flow) {
        n.transform.e = nan;
        n.transform.f = nan;
    }
    if (lay.axisMode(n, in_flow, true) != .fixed) n.size.x = nan;
    if (lay.axisMode(n, in_flow, false) != .fixed) n.size.y = nan;
    for (n.children) |*c| garble(n, c);
}

fn compare(ck: *Check, parent: *const m.Node, s: *const m.Node, g: *const m.Node) !void {
    ck.nodes += 1;
    const pl = try posLabel(ck.a, parent, s);
    try ck.add(&ck.positions, pl.label, pl.ruled, s, .{ s.transform.e, s.transform.f }, .{ g.transform.e, g.transform.f });
    const sl = try sizeLabel(ck.a, parent, s);
    try ck.add(&ck.sizes, sl.label, sl.ruled, s, .{ s.size.x, s.size.y }, .{ g.size.x, g.size.y });
    for (s.children, g.children) |*sc, *gc| try compare(ck, s, sc, gc);
}

const Label = struct {
    label: []const u8,
    ruled: bool,
};

fn posLabel(a: std.mem.Allocator, parent: *const m.Node, n: *const m.Node) !Label {
    if (parent.kind == .page) return .{
        .label = "(input) top level",
        .ruled = false,
    };
    if (lay.inFlow(parent, n)) {
        const l = parent.layout.?;
        if (l.mode == .grid) return .{
            .label = "grid cell",
            .ruled = true,
        };
        return .{
            .label = try std.fmt.allocPrint(a, "{s}{s} main {s}, cross {s}{s}", .{
                @tagName(l.mode),
                if (l.wrap) " wrap" else "",
                @tagName(l.main),
                @tagName(l.cross),
                if (l.strokes_included) ", strokes in layout" else "",
            }),
            .ruled = true,
        };
    }
    if (parent.layout != null and parent.kind.isContainer() and n.absolute) return .{
        .label = "(input) absolute in auto layout",
        .ruled = false,
    };
    if (parent.kind == .group) return .{
        .label = "(input) in a group",
        .ruled = false,
    };
    if (parent.layout != null and !n.visible) return .{
        .label = "(input) hidden in auto layout",
        .ruled = false,
    };
    return .{
        .label = "(input) free",
        .ruled = false,
    };
}

fn sizeLabel(a: std.mem.Allocator, parent: *const m.Node, n: *const m.Node) !Label {
    const in_flow = lay.inFlow(parent, n);
    const mx = lay.axisMode(n, in_flow, true);
    const my = lay.axisMode(n, in_flow, false);
    if (mx == .fixed and my == .fixed) return .{
        .label = "(input) fixed",
        .ruled = false,
    };
    const what: []const u8 = switch (n.kind) {
        .text => switch (n.text.?.resize) {
            .width_and_height => "text auto-width",
            .height => "text auto-height",
            else => "text fixed",
        },
        .group => "group bounds",
        .frame, .component, .component_set, .instance => if (n.layout) |l| @tagName(l.mode) else "frame",
        else => @tagName(n.kind),
    };
    return .{
        .label = try std.fmt.allocPrint(a, "{s}: w {s}, h {s}{s}", .{
            what,
            @tagName(mx),
            @tagName(my),
            if (in_flow) (if (parent.layout.?.mode == .vertical) " in column" else if (parent.layout.?.mode == .grid) " in grid" else " in row") else "",
        }),
        .ruled = true,
    };
}

fn printTables(w: *Io.Writer, ck: *Check, show: usize) !void {
    try w.print("{d} nodes; {d} values decided by rules: {d} exact (<= {d} px), {d} close (<= {d} px), {d} wrong\n", .{ ck.nodes, ck.ruled, ck.exact, exact_tol, ck.close, close_tol, ck.wrong });
    inline for (.{ "size", "position" }, .{ &ck.sizes, &ck.positions }) |title, table| {
        try w.print("\n{s:<58} {s:>6} {s:>6} {s:>6} {s:>6} {s:>9}\n", .{ title, "nodes", "exact", "close", "wrong", "worst px" });
        sortTable(table);
        var it = table.iterator();
        while (it.next()) |e| {
            const st = e.value_ptr;
            try w.print("{s:<58} {d:>6} {d:>6} {d:>6} {d:>6} {d:>9.3}\n", .{ e.key_ptr.*[0..@min(58, e.key_ptr.len)], st.count, st.exact, st.close, st.wrong, st.worst });
        }
    }
    if (show == 0) return;
    try w.print("\nworst offenders\n", .{});
    inline for (.{ "size", "position" }, .{ &ck.sizes, &ck.positions }) |title, table| {
        var it = table.iterator();
        while (it.next()) |e| {
            const st = e.value_ptr;
            if (st.offenders.items.len == 0) continue;
            std.mem.sort(Offender, st.offenders.items, {}, struct {
                fn gt(_: void, x: Offender, y: Offender) bool {
                    return x.err > y.err;
                }
            }.gt);
            try w.print("  {s} / {s}\n", .{ title, e.key_ptr.* });
            for (st.offenders.items[0..@min(show, st.offenders.items.len)]) |o| {
                try w.print("    {s:<26} {s:<28} stored {d:.3} {d:.3}  got {d:.3} {d:.3}\n", .{ o.id[0..@min(26, o.id.len)], o.name[0..@min(28, o.name.len)], o.stored[0], o.stored[1], o.got[0], o.got[1] });
            }
        }
    }
}

/// Rules with errors first, then by size.
fn sortTable(t: *Table) void {
    const Ctx = struct {
        values: []const Stats,
        pub fn lessThan(c: @This(), x: usize, y: usize) bool {
            const a = c.values[x];
            const b = c.values[y];
            if ((a.wrong > 0) != (b.wrong > 0)) return a.wrong > 0;
            return a.count > b.count;
        }
    };
    t.sort(Ctx{
        .values = t.values(),
    });
}

fn indexNodes(a: std.mem.Allocator, index: *std.StringHashMapUnmanaged(*const m.Node), n: *const m.Node) !void {
    try index.put(a, n.id, n);
    for (n.children) |*c| try indexNodes(a, index, c);
}

/// For every instance under `n` (and `sn`, the same node in the stored document) whose
/// component is in the document: copy the component's geometry into it, lay it out at the
/// component's size, resize it to its own, and compare its descendants.
fn resetInstances(gpa: std.mem.Allocator, work: *corpus.Loaded, index: *std.StringHashMapUnmanaged(*const m.Node), n: *m.Node, sn: *const m.Node, ck: *Check, resets: *u32, scaled: *u32) !void {
    if (n.kind == .instance and n.scale != 1) {
        // Scaled as a whole: its content is not the component's (not modelled yet).
        scaled.* += 1;
        return;
    }
    if (n.kind == .instance) if (n.component) |cid| if (index.get(cid)) |comp| {
        if (sameShape(n, comp)) {
            resets.* += 1;
            const own = n.size;
            copyGeometry(n, comp);
            n.size = comp.size;
            // Lay out at the component's size, then resize to the instance's.
            _ = try lay.relayoutFrom(gpa, &work.doc, n.id, .{
                .fonts = &work.fonts,
                .size = comp.size,
            });
            _ = try lay.relayoutFrom(gpa, &work.doc, n.id, .{
                .fonts = &work.fonts,
                .size = own,
            });
            for (sn.children, n.children) |*sc, *gc| try compareTree(ck, sn, sc, gc);
            return;
        }
    };
    for (n.children, sn.children) |*c, *sc| try resetInstances(gpa, work, index, c, sc, ck, resets, scaled);
}

fn compareTree(ck: *Check, parent: *const m.Node, s: *const m.Node, g: *const m.Node) !void {
    ck.nodes += 1;
    const pl = try constraintLabel(ck.a, parent, s);
    try ck.add(&ck.positions, pl, true, s, .{ s.transform.e, s.transform.f }, .{ g.transform.e, g.transform.f });
    const sl = try sizeLabel(ck.a, parent, s);
    try ck.add(&ck.sizes, if (sl.ruled) sl.label else try std.fmt.allocPrint(ck.a, "fixed, constraints {s}/{s}", .{ @tagName(s.constraints.h), @tagName(s.constraints.v) }), true, s, .{ s.size.x, s.size.y }, .{ g.size.x, g.size.y });
    for (s.children, g.children) |*sc, *gc| try compareTree(ck, s, sc, gc);
}

fn constraintLabel(a: std.mem.Allocator, parent: *const m.Node, n: *const m.Node) ![]const u8 {
    if (lay.inFlow(parent, n)) return (try posLabel(a, parent, n)).label;
    if (parent.kind == .group) return "in a group";
    return std.fmt.allocPrint(a, "constraints {s}/{s}{s}", .{ @tagName(n.constraints.h), @tagName(n.constraints.v), if (n.absolute) " (absolute)" else "" });
}

/// The instance mirrors the component child for child.
fn sameShape(a: *const m.Node, b: *const m.Node) bool {
    if (a.children.len != b.children.len) return false;
    for (a.children, b.children) |*x, *y| {
        if (x.kind != y.kind) return false;
        if (!sameShape(x, y)) return false;
    }
    return true;
}

/// The component's sizes and positions, everywhere below the instance.
fn copyGeometry(n: *m.Node, comp: *const m.Node) void {
    for (n.children, comp.children) |*c, *s| {
        c.transform = s.transform;
        c.size = s.size;
        copyGeometry(c, s);
    }
}
