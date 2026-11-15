//! A decoded raster image: 8-bit RGBA, straight (not premultiplied) alpha, sRGB.

const std = @import("std");

pub const Image = struct {
    width: u32,
    height: u32,
    /// `width * height * 4` bytes, rows top to bottom, R G B A.
    pixels: []u8,

    pub fn deinit(self: *Image, gpa: std.mem.Allocator) void {
        gpa.free(self.pixels);
        self.* = undefined;
    }
};
