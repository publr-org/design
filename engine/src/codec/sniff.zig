//! An asset's media type and pixel size, read from its first bytes: what a Pubd's
//! `assets` map records for each file.

const std = @import("std");
const jpeg = @import("jpeg.zig");

/// A media type and, for PNG and JPEG, the pixel size (0 when unknown).
pub const Sniffed = struct {
    type: []const u8,
    width: u32 = 0,
    height: u32 = 0,
};

/// Tells PNG, JPEG and GIF apart and reads PNG and JPEG sizes.
pub fn sniff(b: []const u8) Sniffed {
    if (b.len >= 24 and std.mem.eql(u8, b[0..8], "\x89PNG\r\n\x1a\n")) {
        return .{
            .type = "image/png",
            .width = std.mem.readInt(u32, b[16..20], .big),
            .height = std.mem.readInt(u32, b[20..24], .big),
        };
    }
    if (b.len >= 4 and b[0] == 0xFF and b[1] == 0xD8) {
        const info = jpeg.info(b) catch return .{
            .type = "image/jpeg",
        };
        return .{
            .type = "image/jpeg",
            .width = info.width,
            .height = info.height,
        };
    }
    if (b.len >= 6 and std.mem.eql(u8, b[0..3], "GIF")) return .{
        .type = "image/gif",
    };
    return .{
        .type = "application/octet-stream",
    };
}

test "a PNG header gives its type and size" {
    const head = "\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR\x00\x00\x01\x00\x00\x00\x00\x80";
    const s = sniff(head);
    try std.testing.expectEqualStrings("image/png", s.type);
    try std.testing.expectEqual(@as(u32, 256), s.width);
    try std.testing.expectEqual(@as(u32, 128), s.height);
    try std.testing.expectEqualStrings("application/octet-stream", sniff("nope").type);
}
