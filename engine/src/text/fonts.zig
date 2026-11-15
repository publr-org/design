//! Adding font files to a `FontSet`, whatever the host read them from (a folder, the
//! network, a dropped file).

const std = @import("std");
const font_mod = @import("font.zig");
const text_layout = @import("layout.zig");
const woff = @import("woff.zig");

const Font = font_mod.Font;
const FontSet = text_layout.FontSet;

/// What a font file is for.
pub const Role = enum(u32) {
    /// A family's face (a variable font adds one face per named instance).
    face = 0,
    /// Tried in the order added for characters the styled font lacks.
    fallback = 1,
    /// A variable font used only for weights the family's faces do not have.
    variable = 2,
};

/// Parses `bytes` and adds it to `set` as `role`. `arena` must outlive the set: the font
/// keeps pointers into `bytes`, which must live there too. A WOFF or WOFF2 file is
/// converted to sfnt bytes first, kept in `arena`. Fonts that do not parse are skipped
/// (returns false).
pub fn add(set: *FontSet, gpa: std.mem.Allocator, arena: std.mem.Allocator, file: []const u8, role: Role) !bool {
    var bytes = file;
    if (woff.isWoff(file)) {
        const sfnt = woff.toSfnt(gpa, file) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidFont => return false,
        };
        defer gpa.free(sfnt);
        bytes = try arena.dupe(u8, sfnt);
    }
    switch (role) {
        .face => {
            const font = Font.parse(arena, bytes) catch return false;
            // A variable font: one face per named instance, at its coordinates.
            const instances = font.namedInstances(arena) catch &.{};
            if (instances.len != 0) {
                try set.variable.append(gpa, faceOf(font, font.subfamily));
                for (instances) |inst| {
                    var f = font;
                    f.setVariation(inst.values);
                    try set.faces.append(gpa, faceOf(f, inst.subfamily));
                }
                return true;
            }
            try set.faces.append(gpa, faceOf(font, font.subfamily));
            return true;
        },
        .fallback => {
            const font = try arena.create(Font);
            font.* = Font.parse(arena, bytes) catch return false;
            try set.fallbacks.append(gpa, font);
            return true;
        },
        .variable => {
            const font = Font.parse(arena, bytes) catch return false;
            if (font.axes().len == 0) return false;
            try set.variable.append(gpa, faceOf(font, font.subfamily));
            return true;
        },
    }
}

fn faceOf(font: Font, style: []const u8) FontSet.Face {
    return .{
        .family = font.family,
        .style = style,
        .weight = font.weight_class,
        .italic = font.italic,
        .font = font,
    };
}

/// True for the file names `add` is meant for: TrueType, OpenType, collections and web
/// fonts, in any letter case.
pub fn isFontFile(name: []const u8) bool {
    const exts = [_][]const u8{ ".ttf", ".otf", ".ttc", ".otc", ".woff", ".woff2" };
    for (exts) |ext| {
        if (name.len >= ext.len and std.ascii.eqlIgnoreCase(name[name.len - ext.len ..], ext)) return true;
    }
    return false;
}

test "font file names" {
    try std.testing.expect(isFontFile("Inter-Regular.ttf"));
    try std.testing.expect(isFontFile("SuisseWorks-Bold.WOFF2"));
    try std.testing.expect(isFontFile("Saans.woff"));
    try std.testing.expect(isFontFile("Noto.TTC"));
    try std.testing.expect(isFontFile("x.otc"));
    try std.testing.expect(!isFontFile("readme.txt"));
    try std.testing.expect(!isFontFile("woff2"));
}
