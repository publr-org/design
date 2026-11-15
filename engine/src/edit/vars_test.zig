//! Variables in the editing core: changes to variables, collections, bindings and modes,
//! what they set off (only the nodes that use what changed), and their exact undo.

const std = @import("std");
const m = @import("../pubd/model.zig");
const read = @import("../pubd/read.zig");
const write = @import("../pubd/write.zig");
const Session = @import("../session.zig").Session;

const testing = std.testing;
const gpa = testing.allocator;

const fixture =
    \\{"pubd":2,"name":"v","pages":[{"id":"0:1","type":"page","name":"P","children":[
    \\{"id":"1:1","type":"frame","name":"Row","size":[200,40],
    \\ "layout":{"mode":"horizontal","gap":8,"padding":[0,0,0,0],"width":"hug"},"vars":{"gap":"V:space"},"children":[
    \\  {"id":"1:2","type":"rectangle","name":"A","size":[20,20],"fills":[{"type":"solid","color":"#ffffff","var":"V:fg"}],"opacity":1,"vars":{"opacity":"V:fade"}},
    \\  {"id":"1:3","type":"rectangle","name":"B","transform":[1,0,0,1,28,0],"size":[20,20],"fills":[{"type":"solid","color":"#ffffff","var":"V:bg"}]},
    \\  {"id":"1:4","type":"rectangle","name":"Plain","transform":[1,0,0,1,56,0],"size":[20,20],"fills":[{"type":"solid","color":"#123456"}]}]},
    \\{"id":"2:1","type":"component","name":"Chip","transform":[1,0,0,1,0,100],"size":[40,40],
    \\ "fills":[{"type":"solid","color":"#ffffff","var":"V:fg"}],"children":[
    \\  {"id":"2:2","type":"rectangle","name":"Dot","size":[10,10],"fills":[{"type":"solid","color":"#ffffff","var":"V:fg"}]}]},
    \\{"id":"3:0","type":"frame","name":"Dark","transform":[1,0,0,1,0,200],"size":[100,100],"modes":{"C:theme":"dark"},"children":[
    \\  {"id":"3:1","type":"instance","name":"Chip","component":"2:1","size":[40,40],
    \\   "fills":[{"type":"solid","color":"#000000","var":"V:fg"}],"children":[
    \\    {"id":"I3:1;2:2","type":"rectangle","name":"Dot","size":[10,10],"fills":[{"type":"solid","color":"#000000","var":"V:fg"}]}]}]}
    \\]}],
    \\"styles":{"S:1":{"type":"fill","name":"Fg","value":[{"type":"solid","color":"#ffffff","var":"V:fg"}]}},
    \\"collections":{"C:theme":{"name":"Theme","modes":[{"id":"light","name":"Light"},{"id":"dark","name":"Dark"}]}},
    \\"variables":{
    \\ "V:fg":{"name":"fg","collection":"C:theme","type":"color","values":{"light":"#ffffff","dark":"#000000"}},
    \\ "V:bg":{"name":"bg","collection":"C:theme","type":"color","values":{"light":{"alias":"V:fg"},"dark":{"alias":"V:fg"}}},
    \\ "V:space":{"name":"space","collection":"C:theme","type":"number","values":{"light":8,"dark":16}},
    \\ "V:fade":{"name":"fade","collection":"C:theme","type":"number","values":{"light":100,"dark":50}}}}
;

fn open() !*Session {
    const s = try Session.create(gpa);
    errdefer s.destroy();
    try s.loadPubd(fixture);
    return s;
}

fn node(s: *Session, id: []const u8) *m.Node {
    return s.edit.node(id) orelse @panic("missing node");
}

fn doc(s: *Session) ![]u8 {
    return s.pubdJson(gpa);
}

fn expectDoc(s: *Session, want: []const u8) !void {
    const got = try doc(s);
    defer gpa.free(got);
    try testing.expectEqualStrings(want, got);
}

fn red(n: *const m.Node) f32 {
    return n.fills[0].color.r;
}

const green_fg =
    \\{"op":"variable","id":"V:fg","variable":{"name":"fg","collection":"C:theme","type":"color","values":{"light":"#00ff00","dark":"#000000"}}}
;

test "a variable's new value reaches the nodes that use it, and only those; undo puts back exactly" {
    const s = try open();
    defer s.destroy();
    const ed = &s.edit;
    try ed.ensureIndexed();
    const before = try doc(s);
    defer gpa.free(before);
    const plain_rev = node(s, "1:4").rev;
    try ed.apply(green_fg);
    // Bound directly, through an alias, in a main and in a main's layer.
    for ([_][]const u8{ "1:2", "1:3", "2:1", "2:2" }) |id| {
        try testing.expectEqual(@as(f32, 0), red(node(s, id)));
        try testing.expectEqual(@as(f32, 1), node(s, id).fills[0].color.g);
    }
    // A style whose paint follows it too.
    try testing.expect(std.mem.indexOf(u8, s.doc.?.styles[0].value.?, "#00ff00") != null);
    // The instance in the dark frame keeps its dark value.
    try testing.expectEqual(@as(f32, 0), node(s, "3:1").fills[0].color.g);
    try testing.expectEqual(@as(f32, 0), node(s, "I3:1;2:2").fills[0].color.g);
    // A node that uses nothing is not touched (nothing of it redraws).
    try testing.expectEqual(plain_rev, node(s, "1:4").rev);
    const after = try doc(s);
    defer gpa.free(after);
    _ = try ed.undo();
    try expectDoc(s, before);
    _ = try ed.redo();
    try expectDoc(s, after);
}

test "a mode set on a frame holds for everything in it; layout follows a bound gap" {
    const s = try open();
    defer s.destroy();
    const ed = &s.edit;
    try ed.ensureIndexed();
    const before = try doc(s);
    defer gpa.free(before);
    try ed.apply(
        \\{"op":"set","node":"1:1","props":{"modes":{"C:theme":"dark"}}}
    );
    const row = node(s, "1:1");
    try testing.expectEqual(@as(f32, 16), row.layout.?.gap);
    try testing.expectEqual(@as(f32, 0), red(node(s, "1:2")));
    try testing.expectApproxEqAbs(@as(f32, 0.5), node(s, "1:2").opacity, 1e-6);
    try testing.expectEqual(@as(f32, 0), red(node(s, "1:3")));
    // Auto layout ran with the new gap: B sits 16 after A.
    try testing.expectEqual(@as(f32, 36), node(s, "1:3").transform.e);
    _ = try ed.undo();
    try expectDoc(s, before);
}

test "binding a field resolves it; setting it by hand detaches the variable" {
    const s = try open();
    defer s.destroy();
    const ed = &s.edit;
    try ed.ensureIndexed();
    try ed.apply(
        \\{"op":"set","node":"1:4","props":{"vars":{"radius":"V:space"},"fills":[{"type":"solid","color":"#123456","var":"V:fg"}]}}
    );
    const p = node(s, "1:4");
    try testing.expectEqual(@as(f32, 8), p.radius[3]);
    try testing.expectEqual(@as(f32, 1), red(p));
    // A value of its own: the binding goes, the value stays.
    try ed.apply(
        \\{"op":"set","node":"1:4","props":{"radius":3}}
    );
    try testing.expectEqual(@as(f32, 3), node(s, "1:4").radius[0]);
    try testing.expectEqual(@as(usize, 0), node(s, "1:4").vars.len);
    // A fill colour of its own detaches the fill's variable.
    try ed.apply(
        \\{"op":"set","node":"1:4","props":{"fills":[{"type":"solid","color":"#ff0000","var":"V:fg"}]}}
    );
    try testing.expect(node(s, "1:4").fills[0].variable == null);
    try testing.expectEqual(@as(f32, 1), red(node(s, "1:4")));
    // Setting the same value as the variable's keeps the binding.
    try ed.apply(
        \\{"op":"set","node":"1:2","props":{"opacity":1}}
    );
    try testing.expectEqual(@as(usize, 1), node(s, "1:2").vars.len);
}

test "collections and modes change as one step; a deleted variable leaves its last values" {
    const s = try open();
    defer s.destroy();
    const ed = &s.edit;
    try ed.ensureIndexed();
    const before = try doc(s);
    defer gpa.free(before);
    // Dark becomes the default (first) mode: everything without a mode of its own goes
    // dark.
    try ed.apply(
        \\{"op":"collection","id":"C:theme","collection":{"name":"Theme","modes":[{"id":"dark","name":"Dark"},{"id":"light","name":"Light"}]}}
    );
    try testing.expectEqual(@as(f32, 0), red(node(s, "1:2")));
    try testing.expectEqual(@as(f32, 16), node(s, "1:1").layout.?.gap);
    _ = try ed.undo();
    try expectDoc(s, before);
    // Removing a variable: what used it keeps the value it had.
    try ed.apply(
        \\{"op":"variable","id":"V:space","variable":null}
    );
    try testing.expectEqual(@as(usize, 3), s.doc.?.variables.len);
    try testing.expectEqual(@as(f32, 8), node(s, "1:1").layout.?.gap);
    _ = try ed.undo();
    try expectDoc(s, before);
    // A new variable lands where `index` says.
    try ed.apply(
        \\{"op":"variable","id":"V:new","variable":{"name":"new","collection":"C:theme","type":"boolean","values":{"light":true,"dark":false}},"index":0}
    );
    try testing.expectEqualStrings("V:new", s.doc.?.variables[0].id);
    _ = try ed.undo();
    try expectDoc(s, before);
}

test "an instance in another mode is not taken for overriding its bound fields" {
    const s = try open();
    defer s.destroy();
    const ed = &s.edit;
    try ed.ensureIndexed();
    // A change to the main reaches the instance (its overrides are worked out first).
    try ed.apply(
        \\{"op":"set","node":"2:2","props":{"size":[12,12]}}
    );
    try testing.expectEqual(@as(f32, 12), node(s, "I3:1;2:2").size.x);
    const inst = node(s, "3:1");
    for (inst.overrides.?) |o| for (o.keys) |k| try testing.expect(!std.mem.eql(u8, k, "fills"));
    // And a new colour for the variable still reaches the instance, in its mode.
    try ed.apply(
        \\{"op":"variable","id":"V:fg","variable":{"name":"fg","collection":"C:theme","type":"color","values":{"light":"#ffffff","dark":"#0000ff"}}}
    );
    try testing.expectEqual(@as(f32, 1), node(s, "I3:1;2:2").fills[0].color.b);
}

test "the variables survive Pubd JSON, read and written again" {
    const extra =
        \\{"pubd":2,"name":"v","pages":[{"id":"0:1","type":"page","modes":{"C:2":"b"},"children":[
        \\ {"id":"1:1","type":"text","size":[10,10],"text":"x","style":{"family":"Inter","vars":{"size":"V:1"}},
        \\  "fills":[{"type":"linear","stops":[{"at":0,"color":"#000000","var":"V:2"},{"at":1,"color":"#ffffff"}],"handles":[[0,0.5],[1,0.5],[0,1]],"vars":{"opacity":"V:1"}}],
        \\  "effects":[{"type":"drop-shadow","color":"#00000040","offset":[0,2],"radius":4,"vars":{"radius":"V:1","offset/1":"V:1"}}],
        \\  "runs":[{"from":0,"to":1,"style":{"vars":{"lineHeight":"V:1"}}}]},
        \\ {"id":"1:2","type":"frame","size":[10,10],"grids":[{"type":"columns","count":4,"gutter":8,"offset":0,"size":0,"align":"stretch","color":"#ff000019","vars":{"count":"V:1"}}],
        \\  "vars":{"props/x#1":"key:abc"}}]}],
        \\"collections":{"C:1":{"name":"A","modes":[{"id":"a","name":"A"}],"key":"k1","hidden":true,"library":true},
        \\ "C:2":{"name":"A+","modes":[{"id":"b","name":"B","parent":"a"}],"parent":"C:1","overrides":{"V:1":{"b":12}}}},
        \\"variables":{"V:1":{"name":"n","collection":"C:1","type":"number","values":{"a":4},"scopes":["gap"],"key":"vk","hidden":true,"deleted":true,"code":{"web":"var(--n)","ios":"n","android":"n"}},
        \\ "V:2":{"name":"c","collection":"C:1","type":"color","description":"d","values":{"a":{"compose":{"color":"#ff0000","opacity":{"alias":"V:1"}}}}}}}
    ;
    var d1 = try read.fromJson(gpa, extra, .{});
    defer d1.deinit();
    const j1 = try write.toJson(gpa, &d1);
    defer gpa.free(j1);
    var d2 = try read.fromJson(gpa, j1, .{});
    defer d2.deinit();
    const j2 = try write.toJson(gpa, &d2);
    defer gpa.free(j2);
    try testing.expectEqualStrings(j1, j2);
    // Nothing was lost on the way (compared without the writer's indentation).
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const compact = try std.json.Stringify.valueAlloc(arena.allocator(), try read.parseValue(arena.allocator(), j1), .{});
    for ([_][]const u8{ "\"modes\":{\"C:2\":\"b\"}", "\"parent\":\"C:1\"", "\"overrides\":{\"V:1\":{\"b\":12}}", "\"code\":{\"web\":\"var(--n)\"", "\"deleted\":true", "\"key\":\"vk\"", "\"props/x#1\":\"key:abc\"", "\"offset/1\":\"V:1\"", "\"lineHeight\":\"V:1\"", "\"var\":\"V:2\"", "\"count\":\"V:1\"", "\"compose\"" }) |want| {
        if (std.mem.indexOf(u8, compact, want) == null) {
            std.debug.print("missing {s} in {s}\n", .{ want, compact });
            return error.TestUnexpectedResult;
        }
    }
}

test "what the editor reads out: variables, a value at a node, the modes there" {
    const s = try open();
    defer s.destroy();
    const ed = &s.edit;
    const list = try ed.variablesJson(gpa);
    defer gpa.free(list);
    try testing.expect(std.mem.indexOf(u8, list, "\"id\":\"V:space\"") != null);
    const v = try ed.variableValue(gpa, "I3:1;2:2", "V:space");
    defer gpa.free(v);
    try testing.expectEqualStrings("{\"value\":16}", v);
    const modes = try ed.modesAt(gpa, "I3:1;2:2");
    defer gpa.free(modes);
    try testing.expectEqualStrings("[{\"collection\":\"C:theme\",\"mode\":\"dark\",\"set\":\"3:0\"}]", modes);
}

test "the variables table: each variable resolved in every mode of its collection" {
    const s = try open();
    defer s.destroy();
    const ed = &s.edit;
    const table = try ed.variableTable(gpa, "C:theme");
    defer gpa.free(table);
    try testing.expectEqualStrings(
        \\{"V:fg":["#ffffff","#000000"],"V:bg":["#ffffff","#000000"],"V:space":[8,16],"V:fade":[100,50]}
    , table);
    // No collection: every variable in the default modes.
    const all = try ed.variableTable(gpa, "");
    defer gpa.free(all);
    try testing.expectEqualStrings(
        \\{"V:fg":["#ffffff"],"V:bg":["#ffffff"],"V:space":[8],"V:fade":[100]}
    , all);
    try testing.expectError(error.NoSuchCollection, ed.variableTable(gpa, "C:none"));
}

test "an extended collection's table lists its parent's variables with its overrides" {
    const s = try Session.create(gpa);
    defer s.destroy();
    try s.loadPubd(
        \\{"pubd":2,"name":"x","pages":[{"id":"0:1","type":"page","children":[]}],
        \\"collections":{"C:1":{"name":"Base","modes":[{"id":"a","name":"A"},{"id":"b","name":"B"}]},
        \\ "C:2":{"name":"Brand","parent":"C:1","modes":[{"id":"x","name":"X","parent":"a"},{"id":"y","name":"Y","parent":"b"}],"overrides":{"V:1":{"y":3}}}},
        \\"variables":{"V:1":{"name":"n","collection":"C:1","type":"number","values":{"a":1,"b":2}}}}
    );
    const table = try s.edit.variableTable(gpa, "C:2");
    defer gpa.free(table);
    try testing.expectEqualStrings(
        \\{"V:1":[1,3]}
    , table);
}

const paints_fixture =
    \\{"pubd":2,"name":"v","glyphs":["M0 0L1 0L1 1Z"],"pages":[{"id":"0:1","type":"page","name":"P","children":[
    \\{"id":"1:1","type":"frame","name":"Row","size":[500,40],
    \\ "layout":{"mode":"horizontal","gap":8,"padding":[0,0,0,0],"width":"hug"},"children":[
    \\  {"id":"1:2","type":"rectangle","name":"Box","size":[20,20],"strokes":[{"type":"solid","color":"#ffffff","var":"V:fg"}],"stroke":{"weight":1}},
    \\  {"id":"1:3","type":"text","name":"Label","transform":[1,0,0,1,28,0],"size":[20,20],"text":"ab",
    \\   "runs":[{"from":0,"to":2,"fills":[{"type":"solid","color":"#ffffff","var":"V:fg"}]}],
    \\   "glyphs":[[0,0,10,12,0]]}]}
    \\]}],
    \\"collections":{"C:theme":{"name":"Theme","modes":[{"id":"light","name":"Light"},{"id":"dark","name":"Dark"}]}},
    \\"variables":{"V:fg":{"name":"fg","collection":"C:theme","type":"color","values":{"light":"#ffffff","dark":"#000000"}}}}
;

test "a colour variable's new value repaints strokes and text runs without laying anything out" {
    const s = try Session.create(gpa);
    defer s.destroy();
    try s.loadPubd(paints_fixture);
    const ed = &s.edit;
    try ed.ensureIndexed();
    try ed.apply(green_fg);
    try testing.expectEqual(@as(f32, 1), node(s, "1:2").strokes[0].color.g);
    try testing.expectEqual(@as(f32, 0), node(s, "1:2").strokes[0].color.r);
    const t = node(s, "1:3").text.?;
    try testing.expectEqual(@as(f32, 0), t.runs[0].fills.?[0].color.r);
    // The text as its source laid it out still holds: only its paint changed.
    try testing.expectEqual(@as(usize, 1), t.glyphs.len);
    // The row keeps the width it was stored with: a paint lays nothing out again.
    try testing.expectEqual(@as(f32, 500), node(s, "1:1").size.x);
}

test "a paint's new colour is painted again in place, outlines and text kept" {
    const Records = @import("../gpu/records.zig").Records;
    const s = try Session.create(gpa);
    defer s.destroy();
    try s.loadPubd(paints_fixture);
    const ed = &s.edit;
    try ed.ensureIndexed();
    var rec = Records.init(gpa);
    defer rec.deinit();
    try rec.build(s, 0);
    const label = node(s, "1:3");
    const box = node(s, "1:2");
    const whites = paintedIn(&rec, .{ 1, 1, 1 });
    try testing.expect(whites > 0);
    const shape_before = .{ label.shape_rev, box.shape_rev };
    const revs_before = .{ label.rev, box.rev };
    const prims_before = rec.prims.items.len;
    try ed.apply(green_fg);
    // Colours alone: the nodes keep their revisions, their subtrees' move on.
    try testing.expectEqual(revs_before, .{ label.rev, box.rev });
    try testing.expectEqual(shape_before, .{ label.shape_rev, box.shape_rev });
    try rec.update(s, 0);
    // Painted again in place: nothing written at the ends.
    try testing.expectEqual(@as(u32, 4), rec.header.full);
    try testing.expectEqual(prims_before, rec.prims.items.len);
    // The text's kept glyphs still stand (made at the shape it has).
    try testing.expectEqual(label.shape_rev, rec.texts.get(@intFromPtr(label)).?.rev);
    // What was white is drawn again in green, read from the nodes' new paints.
    try testing.expectEqual(whites, paintedIn(&rec, .{ 0, 1, 0 }));
    try testing.expectEqual(@as(usize, 0), paintedIn(&rec, .{ 1, 1, 1 }));
    // A paint's opacity is more than its colour: its node is written again.
    try ed.apply(
        \\{"op":"set","node":"1:2","props":{"strokes":[{"type":"solid","color":"#00ff00","opacity":0.5}]}}
    );
    try testing.expect(box.rev != revs_before[1]);
    try testing.expectEqual(shape_before[1], box.shape_rev);
    try rec.update(s, 0);
    try testing.expectEqual(@as(u32, 0), rec.header.full);
    // A change of shape makes it stale.
    try ed.apply(
        \\{"op":"set","node":"1:2","props":{"size":[30,30]}}
    );
    try testing.expect(box.shape_rev != shape_before[1]);
}

/// How many of the records' live prims paint in `rgb`.
fn paintedIn(rec: anytype, rgb: [3]f32) usize {
    var n: usize = 0;
    for (rec.tops.items) |t| for (rec.prims.items[t.prim_first..][0..t.prim_count]) |p| {
        const c = rec.paints.items[p.paint].color;
        if (c[0] == rgb[0] and c[1] == rgb[1] and c[2] == rgb[2]) n += 1;
    };
    return n;
}
