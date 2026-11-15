//! Tests for everything but the codecs (while they are in progress).
test {
    _ = @import("raster/geom.zig");
    _ = @import("raster/mask.zig");
    _ = @import("raster/pixmap.zig");
    _ = @import("import/figma.zig");
    _ = @import("pubd/model.zig");
    _ = @import("pubd/read.zig");
    _ = @import("pubd/write.zig");
    _ = @import("render/render.zig");
    _ = @import("text/font.zig");
    _ = @import("text/shape.zig");
    _ = @import("text/variation.zig");
}
