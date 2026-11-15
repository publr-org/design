//! Text editing on the canvas: where a text node's characters and lines are, laid out
//! as the canvas draws them, for the caret, the selection highlight and clicks into the
//! text (`.agents/specs/publr-design-editing.md` "Editing on the canvas"). The edits
//! themselves are ordinary `set` changes of `text` and `runs`.

const std = @import("std");
const m = @import("../pubd/model.zig");
const tl = @import("../text/layout.zig");
const render = @import("../render/render.zig");
const Session = @import("../session.zig").Session;

const Allocator = std.mem.Allocator;

/// Text node `id` laid out, as JSON: `len` (UTF-16 units), `lines` ([top, height,
/// baseline, width, x] each, node space), `chars` ([index, x, advance, line] for each
/// character placed, breaks included), `missing` (the faces it asks for that are not
/// here: "Family Style"), and `path` (text on a path: not edited on the canvas).
pub fn layoutJson(s: *Session, gpa: Allocator, id: []const u8) ![]u8 {
    try s.edit.ensureIndexed();
    const n = s.edit.node(id) orelse return error.NoSuchNode;
    const t = if (n.text) |*t| t else return error.NotText;
    var carets: tl.Carets = .{};
    defer carets.deinit(gpa);
    var lay = try tl.layout(gpa, t, n.size, &s.fonts, .{
        .carets = &carets,
    });
    defer lay.deinit(gpa);

    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    var w: std.json.Stringify = .{
        .writer = &out.writer,
    };
    try w.beginObject();
    try w.objectField("len");
    try w.write(utf16Len(t.text));
    try w.objectField("lines");
    try w.beginArray();
    for (lay.lines.items, 0..) |ln, i| {
        const x: f32 = if (i < carets.line_x.items.len) carets.line_x.items[i] else 0;
        try w.write([5]f32{ ln.top, ln.height, ln.baseline, ln.width, x });
    }
    try w.endArray();
    try w.objectField("chars");
    try w.beginArray();
    for (carets.chars.items) |c| {
        try w.beginArray();
        try w.write(c.char);
        try w.write(c.x);
        try w.write(c.adv);
        try w.write(c.line);
        try w.endArray();
    }
    try w.endArray();
    try w.objectField("missing");
    try w.beginArray();
    try writeMissing(&w, s, t.style, .{});
    for (t.runs) |r| try writeMissing(&w, s, r.style, t.style);
    try w.endArray();
    try w.objectField("path");
    try w.write(n.network != null);
    try w.endObject();
    return out.toOwnedSlice();
}

fn writeMissing(w: *std.json.Stringify, s: *Session, st: m.TextStyle, base: m.TextStyle) !void {
    if (render.Renderer.hasFace(&s.fonts, st, base)) return;
    const family = st.family orelse base.family orelse return;
    const style = st.font_style orelse base.font_style orelse "Regular";
    var buf: [256]u8 = undefined;
    const name = std.fmt.bufPrint(&buf, "{s} {s}", .{ family, style }) catch family;
    try w.write(name);
}

fn utf16Len(s: []const u8) u32 {
    var n: u32 = 0;
    var it = (std.unicode.Utf8View.init(s) catch std.unicode.Utf8View.initUnchecked(s)).iterator();
    while (it.nextCodepoint()) |cp| n += if (cp >= 0x10000) 2 else 1;
    return n;
}
