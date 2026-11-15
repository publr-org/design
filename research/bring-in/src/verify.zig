//! Verify (exact): how much of what the source's designs use the plan's tokens cover,
//! what falls outside (most used first, with an example), and whether every token
//! names its evidence.
//!
//! - Colours: a use is covered when a palette colour is within ΔE00 2 of it (opaque
//!   uses; translucent ones are counted apart, by their colour alone).
//! - Text: a use is covered (loose) when an entry has its family, weight and size (to
//!   0.5 px); strict also needs its line height and case.
//! - Spacing (gaps and paddings) and radii: covered when a token is within 0.5 px;
//!   pill radii are covered by a `full` radius.
//! - By binding, per kind (colours, type, spacing, radii, strokes, effects): the share of
//!   uses that bind a source variable at all, and the share that bind one the plan maps
//!   to a token (a `variable` it names, or one it names among the variables the bound
//!   one aliases, in any mode).
//!
//! - Names: every token name is unique (palette and roles together, each other list
//!   on its own); a duplicate fails the run.
//!
//!   verify <evidence.json> <plan.json> <coverage.json>

const std = @import("std");
const color = @import("color.zig");
const parseHex = @import("make.zig").parseHex;

const Io = std.Io;
const Dir = std.Io.Dir;
const A = std.mem.Allocator;
const Value = std.json.Value;

fn arr(v: Value, key: []const u8) []Value {
    if (v != .object) return &.{};
    const x = v.object.get(key) orelse return &.{};
    return if (x == .array) x.array.items else &.{};
}

fn obj(v: Value, key: []const u8) Value {
    if (v != .object) return .null;
    return v.object.get(key) orelse .null;
}

fn str(v: Value, key: []const u8) []const u8 {
    const x = obj(v, key);
    return if (x == .string) x.string else "";
}

fn f(v: Value) f64 {
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |x| x,
        else => -1,
    };
}

fn numOr(v: Value, key: []const u8, d: f64) f64 {
    const x = obj(v, key);
    return if (x == .integer or x == .float) f(x) else d;
}

const Miss = struct {
    what: []const u8,
    uses: f64,
    at: []const u8,
};

const Tally = struct {
    covered: f64 = 0,
    total: f64 = 0,
    misses: std.ArrayList(Miss) = .empty,

    fn add(t: *Tally, a: A, ok: bool, uses: f64, what: []const u8, at: []const u8) !void {
        t.total += uses;
        if (ok) t.covered += uses else try t.misses.append(a, .{
            .what = what,
            .uses = uses,
            .at = at,
        });
    }

    fn write(t: *Tally, s: *std.json.Stringify, name: []const u8) !void {
        std.mem.sort(Miss, t.misses.items, {}, struct {
            fn less(_: void, x: Miss, y: Miss) bool {
                return x.uses > y.uses;
            }
        }.less);
        try s.objectField(name);
        try s.beginObject();
        try s.objectField("covered");
        try s.write(t.covered);
        try s.objectField("total");
        try s.write(t.total);
        try s.objectField("share");
        try s.write(if (t.total > 0) @round(t.covered / t.total * 1000) / 10 else 0);
        try s.objectField("outside");
        try s.beginArray();
        for (t.misses.items[0..@min(t.misses.items.len, 20)]) |x| {
            try s.beginArray();
            try s.write(x.what);
            try s.write(x.uses);
            try s.write(x.at);
            try s.endArray();
        }
        try s.endArray();
        try s.endObject();
    }

    fn share(t: *const Tally) f64 {
        return if (t.total > 0) t.covered / t.total * 100 else 0;
    }
};

fn pct(x: f64, of: f64) f64 {
    return if (of > 0) @round(x / of * 1000) / 10 else 0;
}

/// Every source variable a plan names: `variable` fields, and the values of
/// `variables` objects, anywhere in it.
fn collectVars(a: A, v: Value, out: *std.StringHashMapUnmanaged(void)) !void {
    switch (v) {
        .object => |o| {
            var it = o.iterator();
            while (it.next()) |e| {
                if (std.mem.eql(u8, e.key_ptr.*, "variable") and e.value_ptr.* == .string) {
                    if (e.value_ptr.string.len > 0) try out.put(a, e.value_ptr.string, {});
                } else if (std.mem.eql(u8, e.key_ptr.*, "variables") and e.value_ptr.* == .object) {
                    var vi = e.value_ptr.object.iterator();
                    while (vi.next()) |x| if (x.value_ptr.* == .string) try out.put(a, x.value_ptr.string, {});
                } else try collectVars(a, e.value_ptr.*, out);
            }
        },
        .array => |l| for (l.items) |x| try collectVars(a, x, out),
        else => {},
    }
}

pub fn run(io: Io, gpa: A, w: *Io.Writer, ev_path: []const u8, plan_path: []const u8, out_path: []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const usage_path = try std.fmt.allocPrint(a, "{s}.usage.json", .{if (std.mem.endsWith(u8, ev_path, ".json")) ev_path[0 .. ev_path.len - 5] else ev_path});
    const usage = try std.json.parseFromSliceLeaky(Value, a, try Dir.cwd().readFileAlloc(io, usage_path, a, .limited(1 << 28)), .{});
    const plan = try std.json.parseFromSliceLeaky(Value, a, try Dir.cwd().readFileAlloc(io, plan_path, a, .limited(1 << 26)), .{});

    // Colours.
    var palette: std.ArrayList(color.Lab) = .empty;
    for (arr(obj(plan, "colors"), "palette")) |p| {
        const c = parseHex(str(p, "value"));
        try palette.append(a, color.lab(c.r, c.g, c.b));
    }
    var colors: Tally = .{};
    var tints: Tally = .{};
    for (arr(usage, "colors")) |row| {
        const r = row.array.items;
        const hex = r[0].string;
        const uses = f(r[1]);
        const c = parseHex(hex);
        const lab = color.lab(c.r, c.g, c.b);
        var best: f64 = 1e9;
        for (palette.items) |p| best = @min(best, color.de2000(p, lab));
        const at = if (r.len > 2) r[2].string else "";
        if (c.a >= 0.95) try colors.add(a, best <= 2, uses, hex, at) else try tints.add(a, best <= 2, uses, hex, at);
    }

    // Text.
    var loose: Tally = .{};
    var strict: Tally = .{};
    // Only the uses in the plan's own families: how well the scale fits the faces it keeps.
    var in_fonts: Tally = .{};
    var families: std.StringHashMapUnmanaged([]const u8) = .empty;
    for (arr(plan, "fontRoles")) |r| for (arr(plan, "fonts")) |fo| {
        if (std.mem.eql(u8, str(fo, "token"), str(r, "font"))) try families.put(a, str(r, "role"), str(fo, "family"));
    };
    for (arr(usage, "type")) |row| {
        const r = row.array.items;
        const fam = r[0].string;
        const weight = f(r[1]);
        const size = f(r[2]);
        const lh = f(r[3]);
        const case = r[5].string;
        const uses = f(r[6]);
        var ok_l = false;
        var ok_s = false;
        for (arr(plan, "typeScale")) |e| {
            const efam = if (str(e, "family").len > 0) str(e, "family") else families.get(str(e, "fontRole")) orelse "";
            if (!std.ascii.eqlIgnoreCase(efam, fam)) continue;
            if (numOr(e, "weight", 400) != weight or @abs(numOr(e, "size", 16) - size) > 0.5) continue;
            ok_l = true;
            const elh = numOr(e, "lineHeight", -1);
            const upper = std.mem.eql(u8, str(e, "textTransform"), "uppercase");
            if (@abs(elh - lh) <= 0.5 and upper == std.mem.eql(u8, case, "upper")) ok_s = true;
        }
        const what = try std.fmt.allocPrint(a, "{s} {d} {d}/{s}{s}", .{ fam, weight, size, if (lh < 0) "auto" else try std.fmt.allocPrint(a, "{d}", .{lh}), if (std.mem.eql(u8, case, "none")) "" else try std.fmt.allocPrint(a, " {s}", .{case}) });
        const at = if (r.len > 7) r[7].string else "";
        try loose.add(a, ok_l, uses, what, at);
        try strict.add(a, ok_s, uses, what, at);
        var known = false;
        for (arr(plan, "fonts")) |fo| known = known or std.ascii.eqlIgnoreCase(str(fo, "family"), fam);
        if (known) try in_fonts.add(a, ok_l, uses, what, at);
    }

    // Spacing and radii.
    var spacing: Tally = .{};
    for ([_][]const u8{ "gaps", "paddings" }) |k| for (arr(usage, k)) |row| {
        const r = row.array.items;
        var ok = false;
        for (arr(plan, "spacing")) |t| ok = ok or @abs(numOr(t, "value", -100) - f(r[0])) <= 0.5;
        try spacing.add(a, ok, f(r[1]), try std.fmt.allocPrint(a, "{s} {d}", .{ k[0 .. k.len - 1], f(r[0]) }), if (r.len > 2) r[2].string else "");
    };
    var radii: Tally = .{};
    var has_full = false;
    for (arr(plan, "radii")) |t| has_full = has_full or numOr(t, "value", 0) >= 999;
    for (arr(usage, "radii")) |row| {
        const r = row.array.items;
        var ok = false;
        for (arr(plan, "radii")) |t| ok = ok or @abs(numOr(t, "value", -100) - f(r[0])) <= 0.5;
        try radii.add(a, ok, f(r[1]), try std.fmt.allocPrint(a, "radius {d}", .{f(r[0])}), if (r.len > 2) r[2].string else "");
    }
    try radii.add(a, has_full, f(obj(usage, "pills")), "pill", "");

    // By binding: the source variables the plan maps (every `variable`, and every value
    // of a `variables` object).
    var mapped: std.StringHashMapUnmanaged(void) = .empty;
    try collectVars(a, plan, &mapped);
    const Bind = struct {
        name: []const u8,
        uses: f64 = 0,
        bound: f64 = 0,
        mapped: f64 = 0,
        unmapped: std.StringArrayHashMapUnmanaged(f64) = .empty,
    };
    var binds: std.ArrayList(Bind) = .empty;
    {
        const bo = obj(usage, "bound");
        if (bo == .object) {
            var it = bo.object.iterator();
            while (it.next()) |e| {
                var bd: Bind = .{
                    .name = e.key_ptr.*,
                    .uses = numOr(e.value_ptr.*, "uses", 0),
                };
                for (arr(e.value_ptr.*, "bound")) |row| {
                    const r = row.array.items;
                    const uses = f(r[0]);
                    bd.bound += uses;
                    var ok = false;
                    for (r[1].array.items) |nm| ok = ok or mapped.contains(nm.string);
                    if (ok) bd.mapped += uses else {
                        const gop = try bd.unmapped.getOrPut(a, if (r[1].array.items.len > 0) r[1].array.items[0].string else "?");
                        if (!gop.found_existing) gop.value_ptr.* = 0;
                        gop.value_ptr.* += uses;
                    }
                }
                try binds.append(a, bd);
            }
        }
    }

    // Provenance: every decision names its evidence and a confidence.
    var decisions: u32 = 0;
    var unsupported: std.ArrayList([]const u8) = .empty;
    const lists = [_][]Value{ arr(obj(plan, "colors"), "palette"), arr(obj(plan, "colors"), "roles"), arr(plan, "fonts"), arr(plan, "typeScale"), arr(plan, "spacing"), arr(plan, "radii"), arr(plan, "shadows"), arr(plan, "breakpoints"), arr(plan, "icons"), arr(plan, "components") };
    for (lists) |l| for (l) |d| {
        decisions += 1;
        if (str(d, "evidence").len == 0 or numOr(d, "confidence", -1) < 0 or str(d, "reason").len == 0) {
            try unsupported.append(a, if (str(d, "token").len > 0) str(d, "token") else if (str(d, "key").len > 0) str(d, "key") else str(d, "name"));
        }
    };

    // Token names are unique: one name is one value (a themed role has one value per
    // context, still one name). Palette and roles share the colour names; each other
    // list is its own.
    var dupes: std.ArrayList([]const u8) = .empty;
    {
        const Names = struct {
            fn check(al: A, seen: *std.StringHashMapUnmanaged(void), out: *std.ArrayList([]const u8), l: []Value, key: []const u8) !void {
                for (l) |d| {
                    const n = str(d, key);
                    if (n.len == 0) continue;
                    if ((try seen.getOrPut(al, n)).found_existing) try out.append(al, n);
                }
            }
        };
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        try Names.check(a, &seen, &dupes, arr(obj(plan, "colors"), "palette"), "token");
        try Names.check(a, &seen, &dupes, arr(obj(plan, "colors"), "roles"), "role");
        const List = struct {
            items: []Value,
            key: []const u8,
        };
        const rest = [_]List{
            .{
                .items = arr(plan, "fonts"),
                .key = "token",
            },
            .{
                .items = arr(plan, "typeScale"),
                .key = "key",
            },
            .{
                .items = arr(plan, "spacing"),
                .key = "token",
            },
            .{
                .items = arr(plan, "radii"),
                .key = "token",
            },
            .{
                .items = arr(plan, "shadows"),
                .key = "token",
            },
            .{
                .items = arr(plan, "breakpoints"),
                .key = "key",
            },
        };
        for (rest) |x| {
            var own: std.StringHashMapUnmanaged(void) = .empty;
            try Names.check(a, &own, &dupes, x.items, x.key);
        }
    }

    var aw: std.Io.Writer.Allocating = .init(a);
    var s: std.json.Stringify = .{
        .writer = &aw.writer,
        .options = .{
            .whitespace = .indent_1,
        },
    };
    try s.beginObject();
    try colors.write(&s, "colors_opaque");
    try tints.write(&s, "colors_translucent");
    try loose.write(&s, "text_loose");
    try strict.write(&s, "text_strict");
    try in_fonts.write(&s, "text_in_plan_fonts");
    try spacing.write(&s, "spacing");
    try radii.write(&s, "radii");
    try s.objectField("by_binding");
    try s.beginObject();
    try s.objectField("variables_the_plan_maps");
    try s.write(mapped.count());
    for (binds.items) |*bd| {
        try s.objectField(bd.name);
        try s.beginObject();
        try s.objectField("uses");
        try s.write(bd.uses);
        try s.objectField("bound");
        try s.write(bd.bound);
        try s.objectField("bound_share");
        try s.write(pct(bd.bound, bd.uses));
        try s.objectField("mapped");
        try s.write(bd.mapped);
        try s.objectField("mapped_share");
        try s.write(pct(bd.mapped, bd.uses));
        try s.objectField("mapped_share_of_bound");
        try s.write(pct(bd.mapped, bd.bound));
        // Bound to variables the plan does not map, most used first.
        const keys = bd.unmapped.keys();
        const vals = bd.unmapped.values();
        const idx = try a.alloc(usize, keys.len);
        for (idx, 0..) |*x, i| x.* = i;
        std.mem.sort(usize, idx, vals, struct {
            fn less(v: []const f64, x: usize, y: usize) bool {
                return v[x] > v[y];
            }
        }.less);
        try s.objectField("bound_outside");
        try s.beginArray();
        for (idx[0..@min(idx.len, 15)]) |i| {
            try s.beginArray();
            try s.write(keys[i]);
            try s.write(vals[i]);
            try s.endArray();
        }
        try s.endArray();
        try s.endObject();
    }
    try s.endObject();
    try s.objectField("provenance");
    try s.beginObject();
    try s.objectField("decisions");
    try s.write(decisions);
    try s.objectField("without_evidence");
    try s.write(unsupported.items);
    try s.objectField("duplicate_names");
    try s.write(dupes.items);
    try s.endObject();
    try s.endObject();
    try Dir.cwd().writeFile(io, .{
        .sub_path = out_path,
        .data = aw.written(),
    });
    try w.print("colours {d:.1}% (translucent {d:.1}%), text {d:.1}% loose / {d:.1}% strict ({d:.1}% of the plan's families), spacing {d:.1}%, radii {d:.1}%; {d} decisions, {d} without evidence\n", .{ colors.share(), tints.share(), loose.share(), strict.share(), in_fonts.share(), spacing.share(), radii.share(), decisions, unsupported.items.len });
    try w.writeAll("by binding (bound / bound to a mapped variable):");
    for (binds.items) |bd| try w.print(" {s} {d:.1}% / {d:.1}%", .{ bd.name, pct(bd.bound, bd.uses), pct(bd.mapped, bd.uses) });
    try w.print("; {d} source variables mapped\n", .{mapped.count()});
    if (dupes.items.len > 0) {
        try w.print("duplicate token names ({d}):", .{dupes.items.len});
        for (dupes.items) |n| try w.print(" {s}", .{n});
        try w.writeByte('\n');
        try w.flush();
        return error.DuplicateTokenNames;
    }
}
