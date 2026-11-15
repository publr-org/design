//! PublrEngine: the PublrDesign rendering engine.

pub const Image = @import("codec/image.zig").Image;
pub const png = @import("codec/png.zig");
pub const jpeg = @import("codec/jpeg.zig");
/// Brotli decompression (RFC 7932).
pub const brotli = @import("codec/brotli.zig");
/// An asset's media type and pixel size from its first bytes.
pub const sniff = @import("codec/sniff.zig");
pub const geom = @import("raster/geom.zig");
pub const mask = @import("raster/mask.zig");
pub const pixmap = @import("raster/pixmap.zig");
pub const model = @import("pubd/model.zig");
pub const pubd_read = @import("pubd/read.zig");
pub const pubd_write = @import("pubd/write.zig");
/// Variables: what a variable is worth at a node, and bound fields set to it.
pub const pubd_vars = @import("pubd/vars.zig");
/// Model values as flat bytes between engines of one build (a worker's parsed nodes).
pub const pubd_blob = @import("pubd/blob.zig");
pub const figma = @import("import/figma.zig");
pub const fig = @import("import/fig/fig.zig");
pub const kiwi = @import("import/fig/kiwi.zig");
pub const fig_blobs = @import("import/fig/blobs.zig");
pub const fig_container = @import("import/fig/container.zig");
/// Importing a `.fig` page by page, images one at a time (any size).
pub const fig_stream = @import("import/fig/stream.zig");
/// A document kept page by page: page files and what `document.json` keeps of them.
pub const pages = @import("import/pages.zig");
pub const render = @import("render/render.zig");
pub const diff = @import("diff.zig");
pub const font = @import("text/font.zig");
pub const shape = @import("text/shape.zig");
pub const layout = @import("text/layout.zig");
/// Adding font files to a font set.
pub const fonts = @import("text/fonts.zig");
/// WOFF 1.0 and WOFF 2.0 web fonts to plain sfnt bytes.
pub const woff = @import("text/woff.zig");
/// What a font file holds (faces, axes), for font lists.
pub const font_info = @import("text/font_info.zig");
/// A document open for viewing: bytes in, tiles and hit tests out (the WASM viewer's core).
pub const session = @import("session.zig");
/// The GPU canvas's frame: the scene as flat lists of primitives (`docs/gpu.md`).
pub const gpu_scene = @import("gpu/scene.zig");
/// The GPU canvas's records: a page kept on the GPU in its nodes' units.
pub const gpu_records = @import("gpu/records.zig");
/// Sizes and positions from rules: auto layout, hug and fill, text resizing, constraints.
pub const relayout = @import("layout/layout.zig");
/// Editing: changes, undo and redo, instances following their main components.
pub const edit = @import("edit/editor.zig");
pub const edit_change = @import("edit/change.zig");
pub const edit_props = @import("edit/props.zig");
/// What the canvas's tools ask: node places, drop targets, resize plans.
pub const edit_canvas = @import("edit/canvas.zig");
/// Text editing on the canvas: carets and lines of a text node.
pub const edit_text = @import("edit/text_edit.zig");
/// The live document as an editor's panels read it: layer trees and shape hit tests.
pub const edit_tree = @import("edit/tree.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
