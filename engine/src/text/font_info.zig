//! What a font file holds, as a font list shows it: each face's family, style name,
//! weight and slant, and a variable font's axes. Reads every format `fonts.add` takes
//! (TrueType, OpenType, collections' first face, WOFF and WOFF2).

const std = @import("std");
const fonts = @import("fonts.zig");
const text_layout = @import("layout.zig");

pub const Face = struct {
    family: []const u8,
    style: []const u8,
    weight: u16,
    italic: bool,
};

pub const AxisInfo = struct {
    tag: []const u8,
    min: f32,
    default: f32,
    max: f32,
};

pub const Info = struct {
    /// The faces (a variable font: one per named instance).
    faces: []Face,
    /// A variable font's axes (empty for a static font).
    axes: []AxisInfo,
};

/// The faces and axes of the font file `bytes`, as JSON (in `gpa`); error.InvalidFont
/// when it does not parse.
pub fn json(gpa: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var set: text_layout.FontSet = .{};
    defer set.deinit(gpa);
    if (!try fonts.add(&set, gpa, a, bytes, .face)) return error.InvalidFont;
    const faces = try a.alloc(Face, set.faces.items.len);
    for (faces, set.faces.items) |*o, f| o.* = .{
        .family = f.family,
        .style = f.style,
        .weight = f.weight,
        .italic = f.italic,
    };
    var axes: std.ArrayList(AxisInfo) = .empty;
    for (set.variable.items) |v| for (v.font.axes()) |ax| try axes.append(a, .{
        .tag = try a.dupe(u8, &ax.tag),
        .min = ax.min,
        .default = ax.default,
        .max = ax.max,
    });
    const info: Info = .{
        .faces = faces,
        .axes = axes.items,
    };
    return std.json.Stringify.valueAlloc(gpa, info, .{});
}
