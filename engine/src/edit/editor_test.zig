//! The editing core's tests: changes and their inverses, steps, components with
//! instances and overrides, replicas, and what an edit invalidates on the GPU.

const std = @import("std");
const m = @import("../pubd/model.zig");
const read = @import("../pubd/read.zig");
const write = @import("../pubd/write.zig");
const Session = @import("../session.zig").Session;
const scene_mod = @import("../gpu/scene.zig");
const Editor = @import("editor.zig").Editor;

const testing = std.testing;
const gpa = testing.allocator;

const fixture =
    \\{"pubd":1,"name":"t","pages":[{"id":"0:1","type":"page","name":"P","children":[
    \\{"id":"2:1","type":"component","name":"Button","size":[100,40],
    \\ "fills":[{"type":"solid","color":"#ff0000"}],
    \\ "properties":[{"id":"label#1","name":"Label","type":"text","default":"OK"},{"id":"icon#2","name":"Icon","type":"boolean","default":true}],
    \\ "children":[
    \\  {"id":"2:2","type":"text","name":"Label","transform":[1,0,0,1,10,10],"size":[40,20],"text":"OK","style":{"family":"Inter","size":14},"bind":{"text":"label#1"}},
    \\  {"id":"2:3","type":"rectangle","name":"Icon","transform":[1,0,0,1,70,12],"size":[16,16],"fills":[{"type":"solid","color":"#0000ff"}],"bind":{"visible":"icon#2"}}]},
    \\{"id":"3:1","type":"instance","name":"Button","component":"2:1","transform":[1,0,0,1,0,100],"size":[100,40],
    \\ "fills":[{"type":"solid","color":"#ff0000"}],"children":[
    \\  {"id":"I3:1;2:2","type":"text","name":"Label","transform":[1,0,0,1,10,10],"size":[40,20],"text":"OK","style":{"family":"Inter","size":14},"bind":{"text":"label#1"}},
    \\  {"id":"I3:1;2:3","type":"rectangle","name":"Icon","transform":[1,0,0,1,70,12],"size":[16,16],"fills":[{"type":"solid","color":"#0000ff"}],"bind":{"visible":"icon#2"}}]},
    \\{"id":"3:2","type":"instance","name":"Button","component":"2:1","transform":[1,0,0,1,0,200],"size":[100,40],
    \\ "fills":[{"type":"solid","color":"#ff0000"}],"children":[
    \\  {"id":"I3:2;2:2","type":"text","name":"Label","transform":[1,0,0,1,10,10],"size":[40,20],"text":"Cancel","style":{"family":"Inter","size":14},"bind":{"text":"label#1"}},
    \\  {"id":"I3:2;2:3","type":"rectangle","name":"Icon","transform":[1,0,0,1,70,12],"size":[16,16],"fills":[{"type":"solid","color":"#0000ff"}],"bind":{"visible":"icon#2"}}]},
    \\{"id":"4:0","type":"component-set","name":"Chip","transform":[1,0,0,1,300,0],"size":[200,100],"children":[
    \\  {"id":"4:1","type":"component","name":"State=Default","transform":[1,0,0,1,10,10],"size":[80,30],"fills":[{"type":"solid","color":"#00ff00"}],
    \\   "children":[{"id":"4:3","type":"rectangle","name":"Dot","size":[10,10],"fills":[{"type":"solid","color":"#ffffff"}]}]},
    \\  {"id":"4:2","type":"component","name":"State=Hover","transform":[1,0,0,1,100,10],"size":[80,30],"fills":[{"type":"solid","color":"#ffff00"}],
    \\   "children":[{"id":"4:4","type":"rectangle","name":"Dot","size":[12,12],"fills":[{"type":"solid","color":"#000000"}]}]}]},
    \\{"id":"5:1","type":"instance","name":"Chip","component":"4:1","transform":[1,0,0,1,300,200],"size":[80,30],
    \\ "fills":[{"type":"solid","color":"#00ff00"}],"children":[{"id":"I5:1;4:3","type":"rectangle","name":"Dot","size":[10,10],"fills":[{"type":"solid","color":"#ffffff"}]}]},
    \\{"id":"6:1","type":"frame","name":"Row","transform":[1,0,0,1,0,400],"size":[70,30],
    \\ "layout":{"mode":"horizontal","gap":10,"padding":[5,5,5,5],"width":"hug"},"children":[
    \\  {"id":"6:2","type":"rectangle","name":"A","transform":[1,0,0,1,5,5],"size":[20,20],"fills":[{"type":"solid","color":"#336699"}]},
    \\  {"id":"6:3","type":"rectangle","name":"B","transform":[1,0,0,1,35,5],"size":[30,20],"fills":[{"type":"solid","color":"#993366"}]}]},
    \\{"id":"7:1","type":"rectangle","name":"Free","transform":[1,0,0,1,500,500],"size":[50,50],"fills":[{"type":"solid","color":"#123456"}]}
    \\]}]}
;

fn open() !*Session {
    const s = try Session.create(gpa);
    errdefer s.destroy();
    try s.loadPubd(fixture);
    return s;
}

fn json(s: *Session) ![]u8 {
    return s.pubdJson(gpa);
}

fn node(s: *Session, id: []const u8) *m.Node {
    return s.edit.node(id) orelse {
        std.debug.print("no node {s}\n", .{id});
        @panic("missing node");
    };
}

fn expectSameDoc(s: *Session, want: []const u8) !void {
    const got = try json(s);
    defer gpa.free(got);
    try testing.expectEqualStrings(want, got);
}

fn fill(n: *const m.Node) m.Color {
    return n.fills[0].color;
}

test "every change undoes to the same document, and redoes to the same again" {
    const s = try open();
    defer s.destroy();
    const before = try json(s);
    defer gpa.free(before);
    const ed = &s.edit;
    const changes = [_][]const u8{
        \\{"op":"set","node":"6:2","props":{"fills":[{"type":"solid","color":"#ff00ff"}],"opacity":0.5}}
        ,
        \\{"op":"insert","parent":"6:1","index":1,"node":{"id":"9:1","type":"rectangle","name":"New","size":[15,20],"fills":[{"type":"solid","color":"#000000"}]}}
        ,
        \\{"op":"delete","node":"6:3"}
        ,
        \\{"op":"move","node":"7:1","parent":"6:1","index":0}
        ,
        \\{"op":"style","id":"S:1","style":{"type":"fill","name":"Brand","value":[{"type":"solid","color":"#ff0000"}]}}
        ,
        \\{"op":"insert","parent":"","index":1,"node":{"id":"9:2","type":"page","name":"Second","children":[{"id":"9:3","type":"ellipse","size":[10,10]}]}}
        ,
        \\{"op":"set","node":"","props":{"name":"Renamed"}}
        ,
        \\{"op":"set","node":"I3:1;2:2","props":{"text":"Hi"}}
        ,
        \\{"op":"delete","node":"9:2"}
        ,
    };
    for (changes) |c| try ed.apply(c);
    // The row hugs what is in it now: layout ran and was recorded.
    try testing.expectEqual(@as(f32, 5 + 50 + 10 + 20 + 10 + 15 + 5), node(s, "6:1").size.x);
    const after = try json(s);
    defer gpa.free(after);
    for (changes) |_| _ = (try ed.undo()).?;
    try testing.expect(try ed.undo() == null);
    try expectSameDoc(s, before);
    for (changes) |_| _ = (try ed.redo()).?;
    try expectSameDoc(s, after);
    for (changes) |_| _ = try ed.undo();
    try expectSameDoc(s, before);
}

test "a drag is one step, and undo puts back the selection" {
    const s = try open();
    defer s.destroy();
    const ed = &s.edit;
    try ed.setSelection("[\"7:1\"]");
    try ed.begin();
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        var buf: [128]u8 = undefined;
        const c = try std.fmt.bufPrint(&buf, "{{\"op\":\"set\",\"node\":\"7:1\",\"props\":{{\"transform\":[1,0,0,1,{d},500]}}}}", .{500 + i});
        try ed.apply(c);
    }
    try ed.setSelection("[\"6:2\"]");
    try ed.commit();
    try testing.expectEqual(@as(usize, 1), ed.undo_stack.items.len);
    try testing.expectEqual(@as(usize, 1), ed.undo_stack.items[0].entries.items.len);
    try testing.expectEqual(@as(f32, 549), node(s, "7:1").transform.e);
    const back = (try ed.undo()).?;
    try testing.expectEqualStrings("[\"7:1\"]", back.selection);
    try testing.expectEqual(@as(f32, 500), node(s, "7:1").transform.e);
    const fwd = (try ed.redo()).?;
    try testing.expectEqualStrings("[\"6:2\"]", fwd.selection);
    try testing.expectEqual(@as(f32, 549), node(s, "7:1").transform.e);
    // A new edit drops what was undone.
    _ = try ed.undo();
    try ed.apply("{\"op\":\"set\",\"node\":\"7:1\",\"props\":{\"name\":\"X\"}}");
    try testing.expect(!ed.canRedo());
    // Escape in a drag puts everything back.
    try ed.begin();
    try ed.apply("{\"op\":\"set\",\"node\":\"7:1\",\"props\":{\"opacity\":0.2}}");
    try ed.cancel();
    try testing.expectEqual(@as(f32, 1), node(s, "7:1").opacity);
    try testing.expectEqual(@as(usize, 1), ed.undo_stack.items.len);
}

test "a layer held in its auto layout keeps its slot while dragged, and lands in it" {
    const s = try open();
    defer s.destroy();
    const ed = &s.edit;
    try ed.begin();
    try ed.hold(&.{"6:2"});
    try ed.apply("{\"op\":\"set\",\"node\":\"6:2\",\"props\":{\"transform\":[1,0,0,1,100,50]}}");
    try testing.expectEqual(@as(f32, 100), node(s, "6:2").transform.e);
    try testing.expectEqual(@as(f32, 35), node(s, "6:3").transform.e);
    // Moved past B: B takes the first slot, A stays under the pointer.
    try ed.apply("{\"op\":\"move\",\"node\":\"6:2\",\"parent\":\"6:1\",\"index\":1}");
    try testing.expectEqual(@as(f32, 5), node(s, "6:3").transform.e);
    try testing.expectEqual(@as(f32, 100), node(s, "6:2").transform.e);
    try ed.commit();
    try testing.expectEqual(@as(f32, 45), node(s, "6:2").transform.e);
    try testing.expectEqual(@as(f32, 5), node(s, "6:2").transform.f);
    try testing.expectEqual(@as(usize, 1), ed.undo_stack.items.len);
    _ = try ed.undo();
    try testing.expectEqual(@as(f32, 5), node(s, "6:2").transform.e);
    try testing.expectEqual(@as(f32, 35), node(s, "6:3").transform.e);
}

test "a main component's changes reach its instances, but for what they override" {
    const s = try open();
    defer s.destroy();
    const before = try json(s);
    defer gpa.free(before);
    const ed = &s.edit;
    try ed.apply("{\"op\":\"set\",\"node\":\"2:3\",\"props\":{\"fills\":[{\"type\":\"solid\",\"color\":\"#00ff00\"}]}}");
    try testing.expectEqual(@as(f32, 1), fill(node(s, "I3:1;2:3")).g);
    try testing.expectEqual(@as(f32, 1), fill(node(s, "I3:2;2:3")).g);
    // The second instance's text differs from the main's: an override, worked out.
    const ov = node(s, "3:2").overrides.?;
    try testing.expectEqual(@as(usize, 1), ov.len);
    try testing.expectEqualStrings("2:2", ov[0].path);
    try testing.expectEqualStrings("text", ov[0].keys[0]);
    try ed.apply("{\"op\":\"set\",\"node\":\"2:2\",\"props\":{\"text\":\"Go\"}}");
    try testing.expectEqualStrings("Go", node(s, "I3:1;2:2").text.?.text);
    try testing.expectEqualStrings("Cancel", node(s, "I3:2;2:2").text.?.text);
    // The main's fill on the instance itself.
    try ed.apply("{\"op\":\"set\",\"node\":\"2:1\",\"props\":{\"fills\":[{\"type\":\"solid\",\"color\":\"#0000ff\"}],\"transform\":[1,0,0,1,7,7]}}");
    try testing.expectEqual(@as(f32, 1), fill(node(s, "3:1")).b);
    try testing.expectEqual(@as(f32, 100), node(s, "3:1").transform.f);
    for (0..3) |_| _ = try ed.undo();
    try expectSameDoc(s, before);
}

test "an edit inside an instance is an override, and resetting puts the main back" {
    const s = try open();
    defer s.destroy();
    const ed = &s.edit;
    try ed.apply("{\"op\":\"set\",\"node\":\"I3:1;2:3\",\"props\":{\"fills\":[{\"type\":\"solid\",\"color\":\"#ffff00\"}]}}");
    const ov = node(s, "3:1").overrides.?;
    try testing.expectEqual(@as(usize, 1), ov.len);
    try testing.expectEqualStrings("2:3", ov[0].path);
    try testing.expectEqualStrings("fills", ov[0].keys[0]);
    try ed.apply("{\"op\":\"set\",\"node\":\"2:3\",\"props\":{\"fills\":[{\"type\":\"solid\",\"color\":\"#00ff00\"}]}}");
    try testing.expectEqual(@as(f32, 0), fill(node(s, "I3:1;2:3")).b);
    try testing.expectEqual(@as(f32, 1), fill(node(s, "I3:1;2:3")).r);
    try ed.apply("{\"op\":\"reset\",\"node\":\"I3:1;2:3\"}");
    try testing.expectEqual(@as(f32, 0), fill(node(s, "I3:1;2:3")).r);
    try testing.expectEqual(@as(f32, 1), fill(node(s, "I3:1;2:3")).g);
    try testing.expectEqual(@as(usize, 0), node(s, "3:1").overrides.?.len);
    // It follows again.
    try ed.apply("{\"op\":\"set\",\"node\":\"2:3\",\"props\":{\"fills\":[{\"type\":\"solid\",\"color\":\"#ff0000\"}]}}");
    try testing.expectEqual(@as(f32, 1), fill(node(s, "I3:1;2:3")).r);
    // Reset all on an instance.
    try ed.apply("{\"op\":\"reset\",\"node\":\"3:2\"}");
    try testing.expectEqualStrings("OK", node(s, "I3:2;2:2").text.?.text);
    _ = try ed.undo();
    try testing.expectEqualStrings("Cancel", node(s, "I3:2;2:2").text.?.text);
}

test "component properties drive the layers bound to them" {
    const s = try open();
    defer s.destroy();
    const ed = &s.edit;
    try ed.apply("{\"op\":\"prop\",\"node\":\"3:1\",\"prop\":\"label#1\",\"value\":\"Hello\"}");
    try testing.expectEqualStrings("Hello", node(s, "I3:1;2:2").text.?.text);
    try testing.expectEqualStrings("label#1", node(s, "3:1").props[0].id);
    try ed.apply("{\"op\":\"prop\",\"node\":\"3:1\",\"prop\":\"icon#2\",\"value\":false}");
    try testing.expect(!node(s, "I3:1;2:3").visible);
    // A main change does not reach a property set on the instance.
    try ed.apply("{\"op\":\"set\",\"node\":\"2:2\",\"props\":{\"text\":\"Go\"}}");
    try testing.expectEqualStrings("Hello", node(s, "I3:1;2:2").text.?.text);
    try ed.apply("{\"op\":\"prop\",\"node\":\"3:1\",\"prop\":\"label#1\",\"value\":null}");
    try testing.expectEqualStrings("Go", node(s, "I3:1;2:2").text.?.text);
    try testing.expectEqual(@as(usize, 1), node(s, "3:1").props.len);
}

test "a variant switch takes the other variant's content and keeps overrides by name" {
    const s = try open();
    defer s.destroy();
    const before = try json(s);
    defer gpa.free(before);
    const ed = &s.edit;
    try ed.apply("{\"op\":\"set\",\"node\":\"I5:1;4:3\",\"props\":{\"opacity\":0.5}}");
    try ed.apply("{\"op\":\"prop\",\"node\":\"5:1\",\"prop\":\"State\",\"value\":\"Hover\"}");
    const x = node(s, "5:1");
    try testing.expectEqualStrings("4:2", x.component.?);
    try testing.expectEqual(@as(usize, 1), x.children.len);
    try testing.expectEqualStrings("I5:1;4:4", x.children[0].id);
    // The main's content, with the override carried to the layer of the same name.
    try testing.expectEqual(@as(f32, 12), x.children[0].size.x);
    try testing.expectEqual(@as(f32, 0.5), x.children[0].opacity);
    try testing.expectEqualStrings("4:4", x.overrides.?[0].path);
    // The new main's changes reach it.
    try ed.apply("{\"op\":\"set\",\"node\":\"4:4\",\"props\":{\"name\":\"Spot\"}}");
    try testing.expectEqualStrings("Spot", node(s, "I5:1;4:4").name);
    for (0..3) |_| _ = try ed.undo();
    try expectSameDoc(s, before);
}

test "structure added to a main reaches its instances" {
    const s = try open();
    defer s.destroy();
    const before = try json(s);
    defer gpa.free(before);
    const ed = &s.edit;
    try ed.apply("{\"op\":\"insert\",\"parent\":\"2:1\",\"index\":2,\"node\":{\"id\":\"8:1\",\"type\":\"rectangle\",\"name\":\"Badge\",\"transform\":[1,0,0,1,90,0],\"size\":[8,8]}}");
    try testing.expect(s.edit.node("I3:1;8:1") != null);
    try testing.expect(s.edit.node("I3:2;8:1") != null);
    try ed.apply("{\"op\":\"move\",\"node\":\"8:1\",\"parent\":\"2:1\",\"index\":0}");
    try testing.expectEqualStrings("I3:1;8:1", node(s, "3:1").children[0].id);
    try ed.apply("{\"op\":\"delete\",\"node\":\"2:3\"}");
    try testing.expect(s.edit.node("I3:1;2:3") == null);
    // Inside an instance, structure is the main's.
    try testing.expectError(error.InsideInstance, ed.apply("{\"op\":\"delete\",\"node\":\"I3:1;2:2\"}"));
    for (0..3) |_| _ = try ed.undo();
    try expectSameDoc(s, before);
}

test "an instance inserted with no content takes its main's" {
    const s = try open();
    defer s.destroy();
    const ed = &s.edit;
    try ed.setSelection("[]");
    try ed.apply("{\"op\":\"insert\",\"parent\":\"0:1\",\"node\":{\"type\":\"instance\",\"component\":\"2:1\",\"transform\":[1,0,0,1,0,600]}}");
    const page = &s.doc.?.pages[0];
    const x = &page.children[page.children.len - 1];
    try testing.expectEqual(m.Kind.instance, x.kind);
    try testing.expectEqual(@as(usize, 2), x.children.len);
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings(try std.fmt.bufPrint(&buf, "I{s};2:2", .{x.id}), x.children[0].id);
    try testing.expectEqual(@as(f32, 600), x.transform.f);
    // It follows its main.
    try ed.apply("{\"op\":\"set\",\"node\":\"2:2\",\"props\":{\"text\":\"New\"}}");
    const x2 = s.edit.node(page.children[page.children.len - 1].id).?;
    try testing.expectEqualStrings("New", x2.children[0].text.?.text);
}

test "detaching keeps the look and stops following" {
    const s = try open();
    defer s.destroy();
    const ed = &s.edit;
    try ed.apply("{\"op\":\"detach\",\"node\":\"3:2\"}");
    try testing.expectEqual(m.Kind.frame, node(s, "3:2").kind);
    try ed.apply("{\"op\":\"set\",\"node\":\"2:3\",\"props\":{\"opacity\":0.3}}");
    try testing.expectEqual(@as(f32, 1), node(s, "I3:2;2:3").opacity);
    try testing.expectEqual(@as(f32, 0.3), node(s, "I3:1;2:3").opacity);
}

test "another engine replaying the changes holds the same document" {
    const s = try open();
    defer s.destroy();
    const r = try open();
    defer r.destroy();
    const ed = &s.edit;
    const edits = [_][]const u8{
        "{\"op\":\"set\",\"node\":\"2:3\",\"props\":{\"fills\":[{\"type\":\"solid\",\"color\":\"#00ff00\"}]}}",
        "{\"op\":\"insert\",\"parent\":\"6:1\",\"node\":{\"type\":\"rectangle\",\"size\":[5,5]}}",
        "{\"op\":\"prop\",\"node\":\"5:1\",\"prop\":\"State\",\"value\":\"Hover\"}",
        "{\"op\":\"set\",\"node\":\"I3:1;2:2\",\"props\":{\"text\":\"Hey\"}}",
    };
    for (edits) |e| try ed.apply(e);
    _ = try ed.undo();
    const out = try ed.takeOut(gpa);
    defer gpa.free(out);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), out, .{});
    const changes = try std.json.Stringify.valueAlloc(arena.allocator(), v.object.get("changes").?, .{});
    try r.edit.replay(changes);
    const a = try json(s);
    defer gpa.free(a);
    try expectSameDoc(r, a);
    // Damage is on the page and finite.
    try testing.expect(v.object.get("damage").?.array.items.len > 0);
}

test "documents with components round trip" {
    var doc = try read.fromJson(gpa, fixture, .{});
    defer doc.deinit();
    const once = try write.toJson(gpa, &doc);
    defer gpa.free(once);
    var back = try read.fromJson(gpa, once, .{});
    defer back.deinit();
    const twice = try write.toJson(gpa, &back);
    defer gpa.free(twice);
    try testing.expectEqualStrings(once, twice);
    try testing.expect(std.mem.indexOf(u8, once, "\"type\":\"component-set\"") != null);
    try testing.expect(std.mem.indexOf(u8, once, "\"bind\"") != null);
    try testing.expect(std.mem.indexOf(u8, once, "\"properties\"") != null);
}

test "an edit invalidates only what it changed on the GPU" {
    const s = try open();
    defer s.destroy();
    const Scene = scene_mod.Scene;
    var warm = Scene.init(gpa);
    defer warm.deinit();
    try warm.buildPage(s, 0, 0, 0, 1, 700, 600);
    // The free rectangle changes colour and size.
    try s.edit.apply("{\"op\":\"set\",\"node\":\"7:1\",\"props\":{\"fills\":[{\"type\":\"solid\",\"color\":\"#ff0000\"}],\"size\":[60,40]}}");
    try warm.buildPage(s, 0, 0, 0, 1, 700, 600);
    var fresh = Scene.init(gpa);
    defer fresh.deinit();
    try fresh.buildPage(s, 0, 0, 0, 1, 700, 600);
    try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(fresh.prims.items), std.mem.sliceAsBytes(warm.prims.items));
    try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(fresh.shapes.items), std.mem.sliceAsBytes(warm.shapes.items));
    try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(fresh.paints.items), std.mem.sliceAsBytes(warm.paints.items));
    // A structural change in the row: its siblings move in memory, the frame matches a
    // fresh one again.
    try s.edit.apply("{\"op\":\"insert\",\"parent\":\"6:1\",\"index\":0,\"node\":{\"type\":\"ellipse\",\"size\":[12,12],\"fills\":[{\"type\":\"solid\",\"color\":\"#00ffff\"}]}}");
    try warm.buildPage(s, 0, 0, 0, 1, 700, 600);
    var fresh2 = Scene.init(gpa);
    defer fresh2.deinit();
    try fresh2.buildPage(s, 0, 0, 0, 1, 700, 600);
    try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(fresh2.prims.items), std.mem.sliceAsBytes(warm.prims.items));
    try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(fresh2.shapes.items), std.mem.sliceAsBytes(warm.shapes.items));
    _ = try s.edit.undo();
    _ = try s.edit.undo();
    try warm.buildPage(s, 0, 0, 0, 1, 700, 600);
    var fresh3 = Scene.init(gpa);
    defer fresh3.deinit();
    try fresh3.buildPage(s, 0, 0, 0, 1, 700, 600);
    try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(fresh3.prims.items), std.mem.sliceAsBytes(warm.prims.items));
}

test "a surface's key changes with what is under it, and only then" {
    const s = try Session.create(gpa);
    defer s.destroy();
    try s.loadPubd(
        \\{"pubd":1,"name":"t","pages":[{"id":"0:1","type":"page","name":"P","children":[
        \\{"id":"1:1","type":"frame","name":"F","size":[100,100],"opacity":0.5,"children":[
        \\ {"id":"1:2","type":"rectangle","name":"R","size":[50,50],"fills":[{"type":"solid","color":"#ff0000"}]}]},
        \\{"id":"2:1","type":"frame","name":"G","transform":[1,0,0,1,200,0],"size":[100,100],"opacity":0.5,"children":[
        \\ {"id":"2:2","type":"rectangle","name":"R","size":[50,50],"fills":[{"type":"solid","color":"#ff0000"}]}]}]}]}
    );
    var sc = scene_mod.Scene.init(gpa);
    defer sc.deinit();
    try sc.buildPage(s, 0, 0, 0, 1, 400, 200);
    try testing.expectEqual(@as(usize, 2), sc.surfaces.items.len);
    const k0 = sc.surfaces.items[0].key_lo;
    const k1 = sc.surfaces.items[1].key_lo;
    try s.edit.apply("{\"op\":\"set\",\"node\":\"1:2\",\"props\":{\"opacity\":0.9}}");
    try sc.buildPage(s, 0, 0, 0, 1, 400, 200);
    try testing.expect(sc.surfaces.items[0].key_lo != k0);
    try testing.expectEqual(k1, sc.surfaces.items[1].key_lo);
}

test "what the undo history costs for a drag" {
    const s = try open();
    defer s.destroy();
    const ed = &s.edit;
    try ed.begin();
    for (0..200) |i| {
        var buf: [128]u8 = undefined;
        try ed.apply(try std.fmt.bufPrint(&buf, "{{\"op\":\"set\",\"node\":\"6:2\",\"props\":{{\"size\":[{d},20]}}}}", .{20 + i}));
    }
    try ed.commit();
    const bytes = ed.historyBytes();
    // One entry for the node, one for each node layout moved (the row, its other child).
    try testing.expect(ed.undo_stack.items[0].entries.items.len <= 4);
    try testing.expect(bytes < 4096);
}

test "overrides worked out for an edit inside an instance go with its undo" {
    const s = try open();
    defer s.destroy();
    const before = try json(s);
    defer gpa.free(before);
    const ed = &s.edit;
    try ed.apply("{\"op\":\"set\",\"node\":\"I3:2;2:2\",\"props\":{\"text\":\"X\"}}");
    try testing.expect(node(s, "3:2").overrides != null);
    try ed.apply("{\"op\":\"set\",\"node\":\"2:3\",\"props\":{\"opacity\":0.5}}");
    _ = try ed.undo();
    _ = try ed.undo();
    try testing.expect(node(s, "3:2").overrides == null);
    try expectSameDoc(s, before);
}

test "a change that fails takes back what its call did" {
    const s = try open();
    defer s.destroy();
    const before = try json(s);
    defer gpa.free(before);
    const ed = &s.edit;
    // The override worked out first, then the text key on a rectangle fails.
    try testing.expectError(error.NotText, ed.apply("[{\"op\":\"set\",\"node\":\"7:1\",\"props\":{\"opacity\":0.5}},{\"op\":\"set\",\"node\":\"I3:2;2:3\",\"props\":{\"text\":\"X\"}}]"));
    try expectSameDoc(s, before);
    try testing.expect(!ed.canUndo());
    try ed.begin();
    try ed.apply("{\"op\":\"set\",\"node\":\"7:1\",\"props\":{\"opacity\":0.5}}");
    try testing.expectError(error.NoSuchNode, ed.apply("[{\"op\":\"set\",\"node\":\"7:1\",\"props\":{\"opacity\":0.7}},{\"op\":\"delete\",\"node\":\"nope\"}]"));
    try testing.expectEqual(@as(f32, 0.5), node(s, "7:1").opacity);
    try ed.commit();
    _ = try ed.undo();
    try expectSameDoc(s, before);
}

test "an imported .fig written and read back renders the same" {
    const io = testing.io;
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, "../complete.fig", gpa, .limited(64 << 20)) catch return error.SkipZigTest;
    defer gpa.free(bytes);
    const a = try Session.create(gpa);
    defer a.destroy();
    try a.loadFig(bytes);
    const once = try a.pubdJson(gpa);
    defer gpa.free(once);
    const b = try Session.create(gpa);
    defer b.destroy();
    try b.loadPubd(once);
    const twice = try b.pubdJson(gpa);
    defer gpa.free(twice);
    const c = try Session.create(gpa);
    defer c.destroy();
    try c.loadPubd(twice);
    for (a.doc.?.assets) |as| if (a.assetBytes(as.hash)) |data| {
        try b.addAsset(as.hash, data);
        try c.addAsset(as.hash, data);
    };
    // The same JSON again.
    try testing.expectEqualStrings(once, twice);
    // The same pixels, frame by frame: read once and read again exactly; the import
    // itself and what was read differ only where the file rounds numbers to 1/10000.
    var frames: usize = 0;
    var pixels: usize = 0;
    var off_import: usize = 0;
    var max_import: f32 = 0;
    for (a.doc.?.pages) |pg| for (pg.children) |top| {
        if (top.size.x * top.size.y * 0.0625 > 4e6) continue;
        var pa = try a.renderNode(top.id, 0.25);
        defer pa.deinit(gpa);
        var pb = try b.renderNode(top.id, 0.25);
        defer pb.deinit(gpa);
        var pc = try c.renderNode(top.id, 0.25);
        defer pc.deinit(gpa);
        try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(pb.data), std.mem.sliceAsBytes(pc.data));
        for (pa.data, pb.data) |x, y| {
            pixels += 1;
            var d: f32 = 0;
            for (0..4) |k| d = @max(d, @abs(x[k] - y[k]));
            if (d > 1.0 / 255.0) off_import += 1;
            max_import = @max(max_import, d);
        }
        frames += 1;
    };
    // Measured 2026-10-15: 112 of 7.47M pixels, at most 27/255 (glyph edges).
    try testing.expect(max_import < 0.25);
    try testing.expect(frames > 0);
    try testing.expect(off_import * 10000 < pixels);
}

test "a swapped instance takes its new main's own look" {
    const s = try open();
    defer s.destroy();
    try s.edit.apply("{\"op\":\"prop\",\"node\":\"5:1\",\"prop\":\"State\",\"value\":\"Hover\"}");
    try testing.expectEqual(@as(f32, 1), fill(node(s, "5:1")).r);
    try testing.expectEqual(@as(f32, 1), fill(node(s, "5:1")).g);
    try testing.expectEqual(@as(f32, 0), fill(node(s, "5:1")).b);
}

test "a page opened after its instances' main changed shows the change" {
    const s = try Session.create(gpa);
    defer s.destroy();
    try s.loadPubd(
        \\{"pubd":1,"name":"t","pages":[
        \\{"id":"0:1","type":"page","name":"Components","src":"pages/0-1.json","frames":[]},
        \\{"id":"0:2","type":"page","name":"Screens","src":"pages/0-2.json","frames":[]}]}
    );
    try s.loadPage(0,
        \\{"id":"0:1","type":"page","name":"Components","children":[
        \\{"id":"2:1","type":"component","name":"Tag","size":[60,20],"fills":[{"type":"solid","color":"#ff0000"}],"children":[
        \\ {"id":"2:2","type":"rectangle","name":"Dot","size":[8,8],"fills":[{"type":"solid","color":"#ffffff"}]}]}]}
    );
    const screens =
        \\{"id":"0:2","type":"page","name":"Screens","children":[
        \\{"id":"3:1","type":"instance","name":"Tag","component":"2:1","size":[60,20],"fills":[{"type":"solid","color":"#ff0000"}],"children":[
        \\ {"id":"I3:1;2:2","type":"rectangle","name":"Dot","size":[8,8],"fills":[{"type":"solid","color":"#ffffff"}]}]},
        \\{"id":"3:2","type":"instance","name":"Tag","component":"2:1","size":[60,20],"fills":[{"type":"solid","color":"#ff0000"}],"children":[
        \\ {"id":"I3:2;2:2","type":"rectangle","name":"Dot","size":[8,8],"fills":[{"type":"solid","color":"#000000"}]}]}]}
    ;
    try s.edit.apply("{\"op\":\"set\",\"node\":\"2:2\",\"props\":{\"opacity\":0.5,\"size\":[10,10]}}");
    try s.loadPage(1, screens);
    try testing.expectEqual(@as(f32, 0.5), node(s, "I3:1;2:2").opacity);
    try testing.expectEqual(@as(f32, 10), node(s, "I3:1;2:2").size.x);
    // The other one's own colour stays: compared with the main as it was.
    try testing.expectEqual(@as(f32, 0), fill(node(s, "I3:2;2:2")).r);
    try testing.expectEqual(@as(f32, 0.5), node(s, "I3:2;2:2").opacity);
    // Undo reaches the page that opened since.
    _ = try s.edit.undo();
    try testing.expectEqual(@as(f32, 1), node(s, "I3:1;2:2").opacity);
    try testing.expectEqual(@as(f32, 0), fill(node(s, "I3:2;2:2")).r);
    // A page with changes stays loaded.
    s.unloadPage(1);
    try testing.expect(s.pageLoaded(1));
}

test "a resize drops a stroke outline resolved at the old size, and undo brings it back" {
    const s = try open();
    defer s.destroy();
    try s.edit.apply(
        \\{"op":"set","node":"6:1","props":{"strokes":[{"type":"solid","color":"#000000"}],"stroke":{"weight":2,"outline":[{"winding":"evenodd","d":"M0 0L70 0L70 30L0 30Z M2 2L2 28L68 28L68 2Z"}]}}}
    );
    try testing.expect(node(s, "6:1").stroke.outline.len == 1);
    // A wider child: the hugging row grows and its outline no longer fits.
    try s.edit.apply(
        \\{"op":"set","node":"6:3","props":{"size":[60,20]}}
    );
    try testing.expect(node(s, "6:1").size.x > 70);
    try testing.expectEqual(@as(usize, 0), node(s, "6:1").stroke.outline.len);
    try testing.expectEqual(@as(f32, 2), node(s, "6:1").stroke.weight);
    _ = try s.edit.undo();
    try testing.expectEqual(@as(f32, 70), node(s, "6:1").size.x);
    try testing.expect(node(s, "6:1").stroke.outline.len == 1);
}

test "a page never read can be deleted, and undo lists it again from its file" {
    const s = try Session.create(gpa);
    defer s.destroy();
    try s.loadPubd(
        \\{"pubd":1,"name":"t","pages":[
        \\{"id":"0:1","type":"page","name":"Shown","src":"pages/0-1.json","frames":[]},
        \\{"id":"0:2","type":"page","name":"Never read","src":"pages/0-2.json","frames":[]}]}
    );
    try s.loadPage(0,
        \\{"id":"0:1","type":"page","name":"Shown","children":[]}
    );
    try testing.expect(!s.pageLoaded(1));
    try s.edit.apply("{\"op\":\"delete\",\"node\":\"0:2\"}");
    try testing.expectEqual(@as(usize, 1), s.doc.?.pages.len);
    _ = try s.edit.undo();
    try testing.expectEqual(@as(usize, 2), s.doc.?.pages.len);
    try testing.expectEqualStrings("Never read", s.doc.?.pages[1].name);
    // Back as it was stored: not read, nothing to write, its file the same.
    try testing.expect(!s.pageLoaded(1));
    try testing.expect(!s.edit.isDirty(1));
    try testing.expectEqualStrings("pages/0-2.json", s.pageFile(1).?);
    try s.loadPage(1,
        \\{"id":"0:2","type":"page","name":"Never read","children":[{"id":"5:1","type":"rectangle","name":"R","size":[4,4]}]}
    );
    try testing.expect(node(s, "5:1").size.x == 4);
    // Redo deletes it again.
    _ = try s.edit.redo();
    try testing.expectEqual(@as(usize, 1), s.doc.?.pages.len);
}

test "a page's file says how many changes it holds, so a replica reading it later applies only the rest" {
    const index =
        \\{"pubd":1,"name":"t","pages":[{"id":"0:1","type":"page","name":"P","src":"pages/0-1.json","frames":[]}]}
    ;
    const page =
        \\{"id":"0:1","type":"page","name":"P","children":[{"id":"5:1","type":"rectangle","name":"R","size":[4,4]}]}
    ;
    const s = try Session.create(gpa);
    defer s.destroy();
    try s.loadPubd(index);
    try s.loadPage(0, page);
    try s.edit.apply("{\"op\":\"set\",\"node\":\"5:1\",\"props\":{\"size\":[10,4]}}");
    // Saved after the first change; the second comes after.
    const saved = try s.edit.pageJson(gpa, 0);
    defer gpa.free(saved);
    try s.edit.apply("{\"op\":\"set\",\"node\":\"5:1\",\"props\":{\"opacity\":0.5}}");
    const out = try s.edit.takeOut(gpa);
    defer gpa.free(out);
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, out, .{});
    defer parsed.deinit();
    const changes = parsed.value.object.get("changes").?.array.items;
    try testing.expectEqual(@as(usize, 2), changes.len);
    try testing.expectEqual(@as(i64, 1), changes[0].object.get("edits").?.integer);
    try testing.expectEqual(@as(i64, 2), changes[1].object.get("edits").?.integer);

    // A replica that held both changes reads the saved file: it holds the first.
    const r = try Session.create(gpa);
    defer r.destroy();
    try r.loadPubd(index);
    try r.loadPage(0, saved);
    try testing.expectEqual(@as(u64, 1), r.pages()[0].edits);
    var held: std.ArrayList(std.json.Value) = .empty;
    defer held.deinit(gpa);
    for (changes) |c| if (c.object.get("edits").?.integer > 1) try held.append(gpa, c);
    const rest = try std.json.Stringify.valueAlloc(gpa, held.items, .{});
    defer gpa.free(rest);
    try r.edit.replay(rest);
    try testing.expectEqual(@as(f32, 10), node(r, "5:1").size.x);
    try testing.expectEqual(@as(f32, 0.5), node(r, "5:1").opacity);
    try testing.expectEqual(@as(u64, 2), r.pages()[0].edits);
}

test "a page's instances are written as changes to one copy of their content, and read back the same" {
    // Three instances of one main: as it is, one node changed, one node's content another.
    var doc = try read.fromJson(
        gpa,
        \\{"pubd":1,"name":"t","pages":[{"id":"0:1","type":"page","name":"P","children":[
        \\{"id":"2:1","type":"component","name":"Card","size":[100,40],"children":[
        \\ {"id":"2:2","type":"frame","name":"Row","size":[80,20],"children":[{"id":"2:4","type":"rectangle","name":"A","size":[8,8]}]},
        \\ {"id":"2:3","type":"rectangle","name":"Icon","size":[16,16]}]},
        \\{"id":"3:1","type":"instance","name":"Card","component":"2:1","size":[100,40],"children":[
        \\ {"id":"I3:1;2:2","type":"frame","name":"Row","size":[80,20],"children":[{"id":"I3:1;2:4","type":"rectangle","name":"A","size":[8,8]}]},
        \\ {"id":"I3:1;2:3","type":"rectangle","name":"Icon","size":[16,16]}]},
        \\{"id":"3:2","type":"instance","name":"Card","component":"2:1","size":[100,40],"children":[
        \\ {"id":"I3:2;2:2","type":"frame","name":"Row","size":[80,20],"children":[{"id":"I3:2;2:4","type":"rectangle","name":"A","size":[8,8]}]},
        \\ {"id":"I3:2;2:3","type":"rectangle","name":"Icon","size":[16,16],"opacity":0.5}]},
        \\{"id":"3:3","type":"instance","name":"Card","component":"2:1","size":[100,40],"children":[
        \\ {"id":"I3:3;2:2","type":"frame","name":"Row","size":[80,20],"children":[]},
        \\ {"id":"I3:3;2:3","type":"rectangle","name":"Icon","size":[16,16],"visible":false}]}]}]}
    ,
        .{},
    );
    defer doc.deinit();
    const page = &doc.pages[0];
    const whole = try write.nodeJson(gpa, page, .{
        .exact = false,
    });
    defer gpa.free(whole);
    const file = try write.pageJson(gpa, page);
    defer gpa.free(file);
    try testing.expect(std.mem.indexOf(u8, file, "\"bases\":{\"2:1\":[{\"id\":\"2:2\"") != null);
    try testing.expect(std.mem.indexOf(u8, file, "\"changes\":{}") != null);
    try testing.expect(std.mem.indexOf(u8, file, "\"changes\":{\"2:3\":{\"opacity\":0.5}}") != null);
    try testing.expect(std.mem.indexOf(u8, file, "\"changes\":{\"2:2\":{\"children\":[]},\"2:3\":{\"visible\":false}}") != null);
    try testing.expect(file.len < whole.len);

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const back = try read.pageFromJson(gpa, a, file, .{});
    try testing.expectEqualStrings(whole, try write.nodeJson(a, &back, .{
        .exact = false,
    }));
    // In pieces: the copies from the file less its top-level nodes, each node on its own.
    const spans = try read.childSpans(a, file);
    const head = try std.mem.concat(a, u8, &.{ file[0 .. spans[0] + 1], file[spans[1] - 1 ..] });
    var bases = (try read.basesFromJson(a, head)).?;
    var k: usize = 2;
    while (k < spans.len) : (k += 2) {
        const n = try read.childFromJson(gpa, a, file[spans[k]..spans[k + 1]], &bases, .{});
        try testing.expectEqualStrings(try write.nodeJson(a, &page.children[k / 2 - 1], .{
            .exact = false,
        }), try write.nodeJson(a, &n, .{
            .exact = false,
        }));
    }
}
