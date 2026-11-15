//! Text layout: a text node's characters, styles and box into placed glyphs.
//!
//! Rules observed from Figma (files we made and its renders):
//! - "Auto" line height is the font's `ascender - descender + lineGap`, scaled.
//! - The baseline sits half the extra line height below `ascender * size` (like CSS).
//! - The first glyph's origin is at x = 0; side bearings are not trimmed.
//! - Lines break at spaces when the box has a fixed width; spaces at a line end hang.
//! - Justified lines stretch their inner spaces to the box width; a paragraph's last line
//!   stays left aligned.
//! - Underlines: the font's `post` thickness, the top edge `thickness / 2` below the
//!   `post` underline position (measured on Inter at 15 and 22 px, 1x and 2x); they skip
//!   ink: a gap where a glyph crosses the stroke, reaching one thickness past the ink. Strikethroughs: the OS/2 strikeout size, the top
//!   edge at the OS/2 strikeout position.
//! - Truncation (ending) shows the lines that fit the box height (or `maxLines`); the last
//!   one loses characters until it and an ellipsis fit the width.
//! - Balanced wrapping keeps a paragraph's line count and narrows the lines as far as it
//!   allows (CSS `text-wrap: balance`).
//! - Leading trim to cap height puts the first baseline the font's cap height (rounded)
//!   below the box top; the box ends at the last baseline.
//! - Lists indent by 1.5 x the font size per level (one level less with hanging lists).
//!   Bullets ("•") centre 0.75 x size left of the text; numbers ("1.", tabular figures)
//!   end size / 3 left of it.
//! - Hanging punctuation: an opening quote or bracket that starts a line sits left of the
//!   line's start and takes no width.
//! - Paragraph indent moves each paragraph's first line right.
//! - A weight that the named face does not have comes from the family's variable font
//!   (its `wght` axis at that weight).
//! - Text on a path: one line whose baseline follows the path, each glyph turned to the
//!   path's direction at its middle.

const std = @import("std");
const m = @import("../pubd/model.zig");
const geom = @import("../raster/geom.zig");
const font_mod = @import("font.zig");
const shape_mod = @import("shape.zig");

const Font = font_mod.Font;
const Vec2 = geom.Vec2;

/// The fonts a document can use, by family and face.
pub const FontSet = struct {
    faces: std.ArrayList(Face) = .empty,
    /// Fonts tried in order for characters the styled font lacks.
    fallbacks: std.ArrayList(*const Font) = .empty,
    /// Variable fonts at their default instance, for weights no face has.
    variable: std.ArrayList(Face) = .empty,

    pub const Face = struct {
        family: []const u8,
        /// The face name as design tools show it ("Bold Italic").
        style: []const u8,
        weight: u16,
        italic: bool,
        font: Font,
    };

    pub fn deinit(self: *FontSet, gpa: std.mem.Allocator) void {
        self.faces.deinit(gpa);
        self.fallbacks.deinit(gpa);
        self.variable.deinit(gpa);
    }

    /// The best face for a style: exact face name, else nearest weight with the same slant.
    pub fn find(self: *const FontSet, family: []const u8, style: ?[]const u8, weight: u16, italic: bool) ?*const Font {
        var best: ?*const Face = null;
        var best_score: i32 = std.math.maxInt(i32);
        for (self.faces.items) |*f| {
            if (!std.ascii.eqlIgnoreCase(f.family, family)) continue;
            if (style) |s| if (std.ascii.eqlIgnoreCase(f.style, s)) return &f.font;
            var score: i32 = @intCast(@abs(@as(i32, f.weight) - @as(i32, weight)));
            if (f.italic != italic) score += 1000;
            if (score < best_score) {
                best_score = score;
                best = f;
            }
        }
        return if (best) |b| &b.font else null;
    }

    /// A variable font of the family whose `wght` axis reaches `weight`, same slant first.
    pub fn findVariable(self: *const FontSet, family: []const u8, weight: u16, italic: bool) ?*const Font {
        var best: ?*const Font = null;
        for (self.variable.items) |*f| {
            if (!std.ascii.eqlIgnoreCase(f.family, family)) continue;
            const w: f32 = @floatFromInt(weight);
            var reaches = false;
            for (f.font.axes()) |a| {
                if (std.mem.eql(u8, &a.tag, "wght") and w >= a.min and w <= a.max) reaches = true;
            }
            if (!reaches) continue;
            if (f.italic == italic) return &f.font;
            if (best == null) best = &f.font;
        }
        return best;
    }
};

/// One glyph ready to draw: its origin on the baseline, in the node's space.
pub const Placed = struct {
    font: *const Font,
    glyph: u16,
    x: f32,
    y: f32,
    size: f32,
    /// Index into `Layout.styles`: what paints it.
    style: u32,
    /// The glyph's direction (text on a path): cosine and sine of its angle.
    cos: f32 = 1,
    sin: f32 = 0,
};

pub const Line = struct {
    top: f32,
    height: f32,
    baseline: f32,
    width: f32,
    /// The letter spacing after the line's last glyph, counted in `width` (an auto-sized
    /// box leaves it out).
    trail: f32 = 0,
};

/// An underline or strikethrough stroke, as a rectangle in node space.
pub const Decoration = struct {
    rect: geom.Rect,
    style: u32,
};

pub const Layout = struct {
    glyphs: std.ArrayList(Placed) = .empty,
    lines: std.ArrayList(Line) = .empty,
    decorations: std.ArrayList(Decoration) = .empty,
    /// Resolved styles; glyphs point into this.
    styles: std.ArrayList(Resolved) = .empty,
    /// Font instances made for this layout (variable weights); glyphs may point at them.
    owned: std.ArrayList(*Font) = .empty,
    /// Characters without a font (missing face).
    missing: u32 = 0,
    width: f32 = 0,
    height: f32 = 0,

    pub fn deinit(self: *Layout, gpa: std.mem.Allocator) void {
        self.glyphs.deinit(gpa);
        self.lines.deinit(gpa);
        self.decorations.deinit(gpa);
        self.styles.deinit(gpa);
        for (self.owned.items) |f| gpa.destroy(f);
        self.owned.deinit(gpa);
    }
};

/// A text style with every field decided.
pub const Resolved = struct {
    family: []const u8,
    font_style: ?[]const u8,
    weight: u16,
    /// The style names a weight (rather than taking the default).
    weight_set: bool = false,
    italic: bool,
    size: f32,
    line_height: m.LineHeight,
    letter_spacing: m.LetterSpacing,
    paragraph_spacing: f32,
    paragraph_indent: f32 = 0,
    case: m.TextCase,
    decoration: m.Decoration,
    /// Run fills, or null for the node's fills.
    fills: ?[]m.Paint,
    /// The run `fills` came from (null: the node's fills): a paint's edit gives the run
    /// new fills, read there while the layout is kept.
    fills_run: ?u32 = null,
    /// The font drawing it (null: none of the document's fonts).
    font: ?*const Font = null,

    fn eql(a: Resolved, b: Resolved) bool {
        return std.mem.eql(u8, a.family, b.family) and
            optEql(a.font_style, b.font_style) and
            a.weight == b.weight and a.weight_set == b.weight_set and
            a.italic == b.italic and a.size == b.size and
            std.meta.eql(a.line_height, b.line_height) and
            std.meta.eql(a.letter_spacing, b.letter_spacing) and
            a.paragraph_spacing == b.paragraph_spacing and
            a.paragraph_indent == b.paragraph_indent and
            a.case == b.case and a.decoration == b.decoration and
            fillsEql(a.fills, b.fills);
    }

    fn fillsEql(a: ?[]m.Paint, b: ?[]m.Paint) bool {
        if (a == null and b == null) return true;
        if (a == null or b == null) return false;
        return a.?.ptr == b.?.ptr;
    }

    fn optEql(a: ?[]const u8, b: ?[]const u8) bool {
        if (a == null and b == null) return true;
        if (a == null or b == null) return false;
        return std.mem.eql(u8, a.?, b.?);
    }
};

fn resolve(base: m.TextStyle, over: m.TextStyle, fills: ?[]m.Paint) Resolved {
    return .{
        .family = over.family orelse base.family orelse "",
        .font_style = over.font_style orelse base.font_style,
        .weight = over.weight orelse base.weight orelse 400,
        .weight_set = over.weight != null or base.weight != null,
        .italic = over.italic orelse base.italic orelse false,
        .size = over.size orelse base.size orelse 16,
        .line_height = over.line_height orelse base.line_height orelse .auto,
        .letter_spacing = over.letter_spacing orelse base.letter_spacing orelse .{
            .px = 0,
        },
        .paragraph_spacing = over.paragraph_spacing orelse base.paragraph_spacing orelse 0,
        .paragraph_indent = over.paragraph_indent orelse base.paragraph_indent orelse 0,
        .case = over.case orelse base.case orelse .none,
        .decoration = over.decoration orelse base.decoration orelse .none,
        .fills = fills,
    };
}

/// The font for a style: its face, or the family's variable font at the style's weight
/// when the face has another weight (or there is no face).
fn styleFont(gpa: std.mem.Allocator, out: *Layout, fonts: *const FontSet, st: Resolved) !?*const Font {
    const face = fonts.find(st.family, st.font_style, st.weight, st.italic);
    if (face) |f| if (!st.weight_set or f.weight_class == st.weight) return f;
    // A family the document asks for that is not here: the first fallback font draws it
    // (missing fonts never mean missing text), at the style's weight when it varies.
    const vf = fonts.findVariable(st.family, st.weight, st.italic) orelse face orelse
        (if (fonts.fallbacks.items.len > 0) fonts.fallbacks.items[0] else return null);
    if (vf == face) return face;
    if (!hasAxis(vf, "wght")) return vf;
    // Reuse an instance this layout already made.
    for (out.owned.items) |o| {
        if (o.data.ptr == vf.data.ptr and o.weight_class == st.weight) return o;
    }
    const inst = try gpa.create(Font);
    errdefer gpa.destroy(inst);
    inst.* = vf.*;
    inst.setVariation(&.{.{
        .tag = "wght".*,
        .value = @floatFromInt(st.weight),
    }});
    try out.owned.append(gpa, inst);
    return inst;
}

fn hasAxis(f: *const Font, tag: *const [4]u8) bool {
    for (f.axes()) |a| if (std.mem.eql(u8, &a.tag, tag)) return true;
    return false;
}

/// A character with where it came from.
const Char = struct {
    cp: u21,
    /// UTF-16 index in the original text.
    u16i: u32,
    style: u32,
    /// Paragraph index (paragraphs end at newlines and paragraph separators).
    para: u32 = 0,
    /// Drawn as a synthesised small capital (the font has none of its own).
    synth: bool = false,
    /// The fallback font drawing this character, when the styled font lacks it.
    fallback: ?*const Font = null,
};

/// A shaped glyph before line breaking.
const Shaped = struct {
    font: *const Font,
    /// The styled font, whose metrics set the line (even for fallback glyphs).
    primary: *const Font,
    glyph: u16,
    /// Pixels.
    advance: f32,
    x_offset: f32,
    y_offset: f32,
    size: f32,
    style: u32,
    /// Index into the char list of the first character it covers.
    char: u32,
};

/// A line being built: a range of shaped glyphs and where it goes.
const LineInfo = struct {
    start: usize,
    end: usize,
    /// Extra glyphs drawn after the range (an ellipsis), also a range of shaped glyphs.
    tail_start: usize = 0,
    tail_end: usize = 0,
    para: u32 = 0,
    /// First and last line of its paragraph.
    first: bool = false,
    last: bool = false,
    /// Left indentation of the text (lists, paragraph indent).
    x0: f32 = 0,
    /// Advance of a hanging punctuation glyph that starts the line.
    hang: f32 = 0,
};

/// A paragraph's list marker: a range of shaped glyphs and how it is placed.
const Marker = struct {
    start: usize = 0,
    end: usize = 0,
    width: f32 = 0,
    size: f32 = 0,
    kind: m.ListType = .none,
};

/// The working state of one layout.
const Work = struct {
    gpa: std.mem.Allocator,
    t: *const m.Text,
    fonts: *const FontSet,
    out: *Layout,
    chars: std.ArrayList(Char) = .empty,
    shaped: std.ArrayList(Shaped) = .empty,

    fn deinit(w: *Work) void {
        w.chars.deinit(w.gpa);
        w.shaped.deinit(w.gpa);
    }

    /// Shapes `utf8` in one style and appends the glyphs (all mapped to char `char`
    /// when `char` is given, else by cluster within `chars[start..end]`).
    fn shapeRun(w: *Work, font: *const Font, primary: *const Font, st: Resolved, style: u32, utf8: []const u8, u16_base: u32, feats: []const shape_mod.Feature, synth: bool, start: usize, end: usize, char: ?u32) !void {
        var glyph_buf: std.ArrayList(shape_mod.Glyph) = .empty;
        defer glyph_buf.deinit(w.gpa);
        try shape_mod.shape(w.gpa, font, utf8, u16_base, feats, &glyph_buf);
        const size = if (synth) st.size * small_caps_scale else st.size;
        const scale = size / @as(f32, @floatFromInt(font.units_per_em));
        const spacing = switch (st.letter_spacing) {
            .px => |v| v,
            .percent => |p| p / 100 * st.size,
        } + if (synth) small_caps_tracking * st.size else 0;
        for (glyph_buf.items) |g| {
            var ci: u32 = @intCast(start);
            if (char) |c| {
                ci = c;
            } else {
                // Map the cluster (UTF-16 index) back to a char index.
                while (ci + 1 < end and w.chars.items[ci + 1].u16i <= g.cluster) ci += 1;
            }
            try w.shaped.append(w.gpa, .{
                .font = font,
                .primary = primary,
                .glyph = g.id,
                .advance = quantize(gridAdvance(font, g) * scale) + spacing,
                .x_offset = @as(f32, @floatFromInt(g.x_offset)) * scale,
                .y_offset = @as(f32, @floatFromInt(g.y_offset)) * scale,
                .size = size,
                .style = style,
                .char = ci,
            });
        }
    }

    fn cpOf(w: *const Work, i: usize) u21 {
        return w.chars.items[w.shaped.items[i].char].cp;
    }

    /// Where the pen starts on a line beginning at glyph `k`: left of zero by the
    /// advance of hanging punctuation.
    fn startX(w: *const Work, k: usize, b: usize) f32 {
        if (!w.t.hanging_punctuation or k >= b) return 0;
        return if (isHanging(w.cpOf(k))) -w.shaped.items[k].advance else 0;
    }

    /// Breaks the glyphs `[a, b)` of one paragraph into lines no wider than `limit`
    /// (less each line's indentation).
    fn breakPara(w: *Work, a: usize, b: usize, limit: f32, x0_first: f32, x0_rest: f32, out: *std.ArrayList(LineInfo)) !void {
        const sh = w.shaped.items;
        var line_start = a;
        var first = true;
        var x = w.startX(a, b);
        var last_break: ?usize = null;
        const n0 = out.items.len;
        var i = a;
        while (i < b) : (i += 1) {
            const g = sh[i];
            const cp = w.cpOf(i);
            const avail = limit - if (first) x0_first else x0_rest;
            if (isBreak(cp)) {
                try out.append(w.gpa, .{
                    .start = line_start,
                    .end = i + 1,
                    .first = first,
                    .x0 = if (first) x0_first else x0_rest,
                });
                line_start = i + 1;
                first = false;
                x = w.startX(line_start, b);
                last_break = null;
                continue;
            }
            if (cp == ' ') {
                x += g.advance;
                last_break = i + 1;
                continue;
            }
            if (x + g.advance > avail + 0.01 and i > line_start) {
                const cut = last_break orelse i;
                try out.append(w.gpa, .{
                    .start = line_start,
                    .end = cut,
                    .first = first,
                    .x0 = if (first) x0_first else x0_rest,
                });
                line_start = cut;
                first = false;
                last_break = null;
                x = w.startX(cut, b);
                var k = cut;
                while (k <= i) : (k += 1) x += sh[k].advance;
                continue;
            }
            x += g.advance;
        }
        const ends_in_line_break = b > a and sh[b - 1].char < w.chars.items.len and !isParaBreak(w.cpOf(b - 1)) and isBreak(w.cpOf(b - 1));
        if (line_start < b or out.items.len == n0 or ends_in_line_break) {
            try out.append(w.gpa, .{
                .start = line_start,
                .end = b,
                .first = first,
                .x0 = if (first) x0_first else x0_rest,
            });
        }
    }

    /// The letter spacing in the advance of a line's last visible glyph.
    fn trailOf(w: *const Work, l: LineInfo) f32 {
        var last: ?usize = null;
        const ranges = [_][2]usize{ .{ l.start, l.end }, .{ l.tail_start, l.tail_end } };
        for (ranges) |r| for (r[0]..r[1]) |i| {
            const cp = w.cpOf(i);
            if (cp != ' ' and !isBreak(cp)) last = i;
        };
        const i = last orelse return 0;
        const g = w.shaped.items[i];
        const st = w.out.styles.items[g.style];
        const synth = g.char < w.chars.items.len and w.chars.items[g.char].synth;
        return switch (st.letter_spacing) {
            .px => |v| v,
            .percent => |p| p / 100 * st.size,
        } + if (synth) small_caps_tracking * st.size else 0;
    }

    /// The width of a line's glyphs (trailing spaces and breaks hang; a leading hanging
    /// glyph takes none).
    fn lineWidth(w: *const Work, l: LineInfo) f32 {
        var width: f32 = 0;
        var trailing: f32 = 0;
        const ranges = [_][2]usize{ .{ l.start, l.end }, .{ l.tail_start, l.tail_end } };
        for (ranges) |r| for (r[0]..r[1]) |i| {
            const g = w.shaped.items[i];
            const cp = w.cpOf(i);
            if (cp == ' ' or isBreak(cp)) {
                trailing += g.advance;
            } else {
                width += trailing + g.advance;
                trailing = 0;
            }
        };
        return width - l.hang;
    }
};

/// Where each character of a laid-out text sits, for a text editor's caret: what
/// `LayoutOptions.carets` adds to a layout.
pub const Carets = struct {
    /// One a character drawn or advanced over (breaks too; not an ellipsis), in order.
    chars: std.ArrayList(Caret) = .empty,
    /// Each line's left edge (where its first character starts).
    line_x: std.ArrayList(f32) = .empty,

    pub const Caret = struct {
        /// The character's UTF-16 index in the text.
        char: u32,
        x: f32,
        /// Its advance (with justification's stretch).
        adv: f32,
        line: u32,
    };

    pub fn deinit(self: *Carets, gpa: std.mem.Allocator) void {
        self.chars.deinit(gpa);
        self.line_x.deinit(gpa);
    }
};

pub const LayoutOptions = struct {
    /// Notes where each character sits.
    carets: ?*Carets = null,
};

pub fn layout(gpa: std.mem.Allocator, t: *const m.Text, box: geom.Vec2, fonts: *const FontSet, options: LayoutOptions) !Layout {
    var out: Layout = .{};
    errdefer out.deinit(gpa);
    var w: Work = .{
        .gpa = gpa,
        .t = t,
        .fonts = fonts,
        .out = &out,
    };
    defer w.deinit();

    // Characters with their style index.
    var n_para: u32 = 1;
    {
        var it = (std.unicode.Utf8View.init(t.text) catch std.unicode.Utf8View.initUnchecked(t.text)).iterator();
        var u16i: u32 = 0;
        while (it.nextCodepoint()) |cp| {
            var over: m.TextStyle = .{};
            var fills: ?[]m.Paint = null;
            var fills_run: ?u32 = null;
            for (t.runs, 0..) |r, ri| if (u16i >= r.from and u16i < r.to) {
                over = r.style;
                fills = r.fills;
                fills_run = if (r.fills != null) @intCast(ri) else null;
            };
            var res = resolve(t.style, over, fills);
            res.fills_run = fills_run;
            var idx: ?u32 = null;
            for (out.styles.items, 0..) |s, i| if (s.eql(res)) {
                idx = @intCast(i);
                break;
            };
            if (idx == null) {
                res.font = try styleFont(gpa, &out, fonts, res);
                try out.styles.append(gpa, res);
                idx = @intCast(out.styles.items.len - 1);
            }
            try w.chars.append(gpa, .{
                .cp = cp,
                .u16i = u16i,
                .style = idx.?,
                .para = n_para - 1,
            });
            if (isParaBreak(cp)) n_para += 1;
            u16i += if (cp >= 0x10000) 2 else 1;
        }
    }
    const chars = w.chars.items;
    applyCase(chars, out.styles.items);
    synthesiseSmallCaps(chars, out.styles.items);
    assignFallbacks(chars, out.styles.items, fonts);

    // Shape each stretch of one style (paragraph breaks split too).
    var utf8: std.ArrayList(u8) = .empty;
    defer utf8.deinit(gpa);
    var start: usize = 0;
    while (start < chars.len) {
        var end = start + 1;
        while (end < chars.len and chars[end].style == chars[start].style and chars[end].synth == chars[start].synth and chars[end].fallback == chars[start].fallback and !isBreak(chars[end - 1].cp)) end += 1;
        const st = out.styles.items[chars[start].style];
        const primary = st.font orelse {
            out.missing += @intCast(end - start);
            start = end;
            continue;
        };
        const font = chars[start].fallback orelse primary;
        utf8.clearRetainingCapacity();
        for (chars[start..end]) |c| try appendUtf8(gpa, &utf8, c.cp);
        var feats: [4]shape_mod.Feature = undefined;
        var nf: usize = 0;
        const synth = chars[start].synth;
        if (!synth) switch (st.case) {
            .small_caps => {
                feats[nf] = .{
                    .tag = "smcp".*,
                };
                nf += 1;
            },
            .small_caps_forced => {
                feats[nf] = .{
                    .tag = "smcp".*,
                };
                feats[nf + 1] = .{
                    .tag = "c2sc".*,
                };
                nf += 2;
            },
            else => {},
        };
        try w.shapeRun(font, primary, st, chars[start].style, utf8.items, chars[start].u16i, feats[0..nf], synth, start, end, null);
        start = end;
    }
    const n_text = w.shaped.items.len;

    // Paragraphs: their glyph ranges, list markers and indentation.
    const wrap = t.resize == .fixed or t.resize == .height or t.resize == .truncate;
    const max_w: f32 = if (wrap) box.x else std.math.inf(f32);
    var infos: std.ArrayList(LineInfo) = .empty;
    defer infos.deinit(gpa);
    var markers: std.ArrayList(Marker) = .empty;
    defer markers.deinit(gpa);
    {
        var counters: [32]u32 = @splat(0);
        var g: usize = 0;
        var p: u32 = 0;
        var para_char: usize = 0;
        while (p < n_para) : (p += 1) {
            const a = g;
            while (g < n_text and chars[w.shaped.items[g].char].para == p) g += 1;
            const b = g;
            // The paragraph's style: its first character's, else the one before it.
            var st_i: u32 = 0;
            while (para_char < chars.len and chars[para_char].para < p) para_char += 1;
            if (para_char < chars.len and chars[para_char].para == p) st_i = chars[para_char].style;
            if (a == b and a > 0) st_i = w.shaped.items[a - 1].style;
            const st = if (out.styles.items.len > 0) out.styles.items[st_i] else resolve(t.style, .{}, null);
            const list: m.ParagraphList = if (p < t.lists.len) t.lists[p] else .{};
            const level = @min(list.indent, 31);

            // The marker.
            var mk: Marker = .{
                .kind = list.type,
                .size = st.size,
            };
            if (list.type == .ordered) {
                counters[level] += 1;
                for (counters[level + 1 ..]) |*c| c.* = 0;
            } else {
                if (list.type == .unordered) counters[level] = 0;
                for (counters[level + 1 ..]) |*c| c.* = 0;
                if (list.type == .none and level == 0) counters = @splat(0);
            }
            if (list.type != .none) if (st.font) |f| {
                var buf: [16]u8 = undefined;
                const text = if (list.type == .ordered) std.fmt.bufPrint(&buf, "{d}.", .{counters[level]}) catch "" else "\u{2022}";
                const tnum = [_]shape_mod.Feature{.{
                    .tag = "tnum".*,
                }};
                mk.start = w.shaped.items.len;
                // Markers map to a character of the paragraph (or the one before).
                const ci: u32 = if (a < b) w.shaped.items[a].char else if (a > 0) w.shaped.items[a - 1].char else 0;
                if (chars.len > 0) {
                    try w.shapeRun(f, f, st, st_i, text, 0, if (list.type == .ordered) &tnum else &.{}, false, ci, ci + 1, ci);
                }
                mk.end = w.shaped.items.len;
                for (w.shaped.items[mk.start..mk.end]) |mg| mk.width += mg.advance;
            };
            try markers.append(gpa, mk);

            // Indentation: list levels, then the paragraph indent on the first line.
            const levels: f32 = @floatFromInt(if (t.hanging_list and level > 0) level - 1 else level);
            const x_list = levels * list_indent * st.size;
            const x_first = x_list + st.paragraph_indent;

            const n0 = infos.items.len;
            try w.breakPara(a, b, max_w, x_first, x_list, &infos);
            if (wrap and t.wrap == .balance and infos.items.len - n0 > 1) {
                // The narrowest width that keeps the line count.
                const count = infos.items.len - n0;
                var lo: f32 = 0;
                var hi: f32 = max_w;
                var it: u32 = 0;
                while (it < 24) : (it += 1) {
                    const mid = (lo + hi) / 2;
                    infos.shrinkRetainingCapacity(n0);
                    try w.breakPara(a, b, mid, x_first, x_list, &infos);
                    if (infos.items.len - n0 <= count) hi = mid else lo = mid;
                }
                infos.shrinkRetainingCapacity(n0);
                try w.breakPara(a, b, hi, x_first, x_list, &infos);
            }
            for (infos.items[n0..]) |*l| l.para = p;
            if (infos.items.len > n0) infos.items[infos.items.len - 1].last = true;
        }
    }
    for (infos.items) |*l| {
        if (t.hanging_punctuation and l.start < l.end and isHanging(w.cpOf(l.start))) l.hang = w.shaped.items[l.start].advance;
    }

    // Lines: heights and baselines.
    var metrics: std.ArrayList(LineMetrics) = .empty;
    defer metrics.deinit(gpa);
    for (infos.items) |l| {
        var lm: LineMetrics = .{
            .height = 0,
            .ascent = 0,
        };
        if (l.start == l.end) {
            // An empty line takes the style of the character before it (or the base style).
            const st_i: u32 = if (l.start > 0) w.shaped.items[l.start - 1].style else 0;
            if (out.styles.items.len > 0) {
                const st = out.styles.items[st_i];
                if (st.font) |f| lm = lineMetrics(f, st);
            }
        }
        for (w.shaped.items[l.start..l.end]) |g| {
            const x = lineMetrics(g.primary, out.styles.items[g.style]);
            lm.height = @max(lm.height, x.height);
            lm.ascent = @max(lm.ascent, x.ascent);
        }
        try metrics.append(gpa, lm);
    }

    // Truncation: the lines that fit, the last one ending in an ellipsis.
    var shown = infos.items.len;
    if (t.truncation == .ending and wrap) {
        var y: f32 = 0;
        var fit: usize = 0;
        for (metrics.items, 0..) |lm, i| {
            y += lm.height;
            if (y > box.y + 0.01 and i > 0) break;
            fit = i + 1;
            if (i + 1 < infos.items.len and infos.items[i].last) y += paraSpacing(&w, infos.items[i]);
        }
        if (t.max_lines) |ml| fit = @min(fit, @max(ml, 1));
        if (fit < infos.items.len) {
            shown = fit;
            try ellipsize(&w, &infos.items[fit - 1], max_w);
        }
    }
    const lines = infos.items[0..shown];

    var y: f32 = 0;
    for (lines, metrics.items[0..shown], 0..) |l, lm, li| {
        try out.lines.append(gpa, .{
            .top = y,
            .height = lm.height,
            .baseline = y + lm.ascent,
            .width = l.x0 + w.lineWidth(l),
            .trail = w.trailOf(l),
        });
        y += lm.height;
        if (li + 1 < lines.len and l.last) y += paraSpacing(&w, l);
    }
    out.height = y;

    // Leading trim: the box runs from the first line's cap height to the last baseline.
    if (t.leading_trim == .cap_height and out.lines.items.len > 0) {
        const first = out.lines.items[0];
        var cap: f32 = 0;
        if (lineFont(&w, lines[0])) |lf| cap = @as(f32, @floatFromInt(lf.font.cap_height)) * lf.size / @as(f32, @floatFromInt(lf.font.units_per_em));
        const trim_top = first.baseline - @round(cap);
        for (out.lines.items) |*ln| {
            ln.top -= trim_top;
            ln.baseline -= trim_top;
        }
        out.height = out.lines.items[out.lines.items.len - 1].baseline;
    }
    for (out.lines.items) |ln| out.width = @max(out.width, ln.width);

    // Vertical alignment within the box.
    // Figma aligns within the node's stored box, which it rounds for auto-sized text.
    const dy: f32 = switch (t.valign) {
        .top => 0,
        // Centred text moves up by half a pixel when the space is odd (whole pixels).
        .center => @floor((box.y - out.height) / 2),
        .bottom => box.y - out.height,
    };
    const box_w = box.x;

    for (lines, out.lines.items, 0..) |l, *line, li| {
        line.top += dy;
        line.baseline += dy;
        const avail = box_w - l.x0;
        const lw = w.lineWidth(l);
        var x: f32 = l.x0 - l.hang + switch (t.@"align") {
            .left, .justify => 0,
            .center => (avail - lw) / 2,
            .right => avail - lw,
        };
        // Justified: inner spaces share what the line lacks of the box width.
        var stretch: f32 = 0;
        var last_ink: usize = l.start;
        for (l.start..l.end) |i| {
            const cp = w.cpOf(i);
            if (cp != ' ' and !isBreak(cp)) last_ink = i;
        }
        if (t.@"align" == .justify and wrap and !l.last and l.tail_end == l.tail_start) {
            var spaces: f32 = 0;
            for (l.start..last_ink) |i| if (w.cpOf(i) == ' ') {
                spaces += 1;
            };
            if (spaces > 0 and avail > lw) stretch = (avail - lw) / spaces;
        }

        // The list marker, left of the text on the paragraph's first line.
        if (l.first) {
            const mk = markers.items[l.para];
            if (mk.kind != .none and mk.end > mk.start) {
                const text_x = x + l.hang;
                var mx = switch (mk.kind) {
                    .unordered => text_x - bullet_centre * mk.size - mk.width / 2,
                    else => text_x - number_gap * mk.size - mk.width,
                };
                for (w.shaped.items[mk.start..mk.end]) |g| {
                    try out.glyphs.append(gpa, .{
                        .font = g.font,
                        .glyph = g.glyph,
                        .x = mx + g.x_offset,
                        .y = line.baseline - g.y_offset,
                        .size = g.size,
                        .style = g.style,
                    });
                    mx += g.advance;
                }
            }
        }

        const deco_from = out.decorations.items.len;
        const glyph_from = out.glyphs.items.len;
        const ranges = [_][2]usize{ .{ l.start, l.end }, .{ l.tail_start, l.tail_end } };
        if (options.carets) |c| try c.line_x.append(gpa, x);
        for (ranges, 0..) |r, ri| for (r[0]..r[1]) |i| {
            const g = w.shaped.items[i];
            const cp = w.cpOf(i);
            if (options.carets) |c| if (ri == 0) try c.chars.append(gpa, .{
                .char = w.chars.items[g.char].u16i,
                .x = x,
                .adv = g.advance + if (cp == ' ' and i < last_ink) stretch else 0,
                .line = @intCast(li),
            });
            if (!isBreak(cp)) try out.glyphs.append(gpa, .{
                .font = g.font,
                .glyph = g.glyph,
                .x = x + g.x_offset,
                .y = line.baseline - g.y_offset,
                .size = g.size,
                .style = g.style,
            });
            const adv = g.advance + if (cp == ' ' and i < last_ink) stretch else 0;
            const st = out.styles.items[g.style];
            if (st.decoration != .none and !isBreak(cp)) try addDecoration(gpa, &out, g, st, x, adv, line.baseline);
            x += adv;
        };
        if (t.skip_ink and out.decorations.items.len > deco_from) try skipInk(gpa, &out, deco_from, out.glyphs.items[glyph_from..]);
    }
    return out;
}

/// Lays text out along the node's network (text on a path): one line whose baseline
/// follows the path from `t.path_start`.
pub fn layoutPath(gpa: std.mem.Allocator, t: *const m.Text, net: *const m.Network, fonts: *const FontSet) !Layout {
    var flat = t.*;
    flat.resize = .width_and_height;
    flat.@"align" = .left;
    flat.valign = .top;
    flat.truncation = .none;
    flat.leading_trim = .none;
    var lay = try layout(gpa, &flat, .{}, fonts, .{});
    errdefer lay.deinit(gpa);
    lay.decorations.clearRetainingCapacity();

    // The path as a polyline with distances along it.
    var pts: std.ArrayList(Vec2) = .empty;
    defer pts.deinit(gpa);
    var dist: std.ArrayList(f32) = .empty;
    defer dist.deinit(gpa);
    const steps = 128;
    var seg = t.path_start.segment;
    var t0 = std.math.clamp(t.path_start.position, 0, 1);
    var visited: usize = 0;
    var at: ?u32 = null;
    while (seg < net.segments.len and visited < net.segments.len) : (visited += 1) {
        const s = net.segments[seg];
        if (s.from >= net.vertices.len or s.to >= net.vertices.len) break;
        if (at) |v| if (v != s.from) break;
        const p0 = net.vertices[s.from];
        const p3 = net.vertices[s.to];
        const p1 = p0.add(s.t0);
        const p2 = p3.add(s.t1);
        var k: u32 = 0;
        while (k <= steps) : (k += 1) {
            const u = t0 + (1 - t0) * @as(f32, @floatFromInt(k)) / steps;
            const p = geom.cubicAt(p0, p1, p2, p3, u);
            if (pts.items.len > 0 and k == 0) continue;
            const d = if (pts.items.len == 0) 0 else dist.items[dist.items.len - 1] + p.sub(pts.items[pts.items.len - 1]).len();
            try pts.append(gpa, p);
            try dist.append(gpa, d);
        }
        t0 = 0;
        at = s.to;
        // The next segment that starts where this one ends.
        var next: ?u32 = null;
        for (net.segments, 0..) |o, oi| if (oi != seg and o.from == s.to) {
            next = @intCast(oi);
            break;
        };
        seg = next orelse break;
    }
    if (pts.items.len < 2) return lay;

    const baseline = if (lay.lines.items.len > 0) lay.lines.items[0].baseline else 0;
    for (lay.glyphs.items) |*g| {
        const adv = @as(f32, @floatFromInt(g.font.advance(g.glyph))) * g.size / @as(f32, @floatFromInt(g.font.units_per_em));
        const mid = g.x + adv / 2;
        const pa = pointAt(pts.items, dist.items, mid);
        const dir = pa[1];
        const normal: Vec2 = .{
            .x = -dir.y,
            .y = dir.x,
        };
        const off = g.y - baseline;
        g.x = pa[0].x - dir.x * adv / 2 + normal.x * off;
        g.y = pa[0].y - dir.y * adv / 2 + normal.y * off;
        g.cos = dir.x;
        g.sin = dir.y;
    }
    return lay;
}

/// The point at distance `d` along a polyline, and the unit direction there; beyond
/// the ends the path continues straight.
fn pointAt(pts: []const Vec2, dist: []const f32, d: f32) [2]Vec2 {
    var i: usize = 1;
    while (i + 1 < pts.len and dist[i] < d) i += 1;
    const a = pts[i - 1];
    const b = pts[i];
    const seg = b.sub(a);
    const l = @max(seg.len(), 1e-6);
    const dir = seg.scale(1 / l);
    return .{ a.add(dir.scale(d - dist[i - 1])), dir };
}

/// Ends a line in an ellipsis: drops characters (and trailing spaces) until the line
/// and the ellipsis fit `limit`.
fn ellipsize(w: *Work, l: *LineInfo, limit: f32) !void {
    // The style of the line's last character (or the one before an empty line).
    while (l.end > l.start and (w.cpOf(l.end - 1) == ' ' or isBreak(w.cpOf(l.end - 1)))) l.end -= 1;
    const last = if (l.end > l.start) l.end - 1 else if (l.start > 0) l.start - 1 else return;
    const g = w.shaped.items[last];
    const st = w.out.styles.items[g.style];
    const font = st.font orelse return;
    l.tail_start = w.shaped.items.len;
    try w.shapeRun(font, font, st, g.style, "\u{2026}", 0, &.{}, false, g.char, g.char + 1, g.char);
    l.tail_end = w.shaped.items.len;
    // The ellipsis needs to fit only up to its ink (its right side bearing may overhang).
    var rsb: f32 = 0;
    if (l.tail_end > l.tail_start) {
        const e = w.shaped.items[l.tail_end - 1];
        if (e.font.glyphBounds(e.glyph)) |bb| {
            rsb = @as(f32, @floatFromInt(@as(i32, e.font.advance(e.glyph)) - bb[2])) * e.size / @as(f32, @floatFromInt(e.font.units_per_em));
        }
    }
    const avail = limit - l.x0 + rsb;
    while (true) {
        while (l.end > l.start and (w.cpOf(l.end - 1) == ' ' or isBreak(w.cpOf(l.end - 1)))) l.end -= 1;
        if (l.end == l.start or w.lineWidth(l.*) <= avail + 0.01) break;
        l.end -= 1;
    }
    l.last = true;
}

/// The extra space after a line that ends a paragraph.
fn paraSpacing(w: *const Work, l: LineInfo) f32 {
    for (l.start..l.end) |i| {
        const cp = w.cpOf(i);
        if (cp == '\n' or cp == 0x2029) return w.out.styles.items[w.shaped.items[i].style].paragraph_spacing;
    }
    return 0;
}

const LineFont = struct {
    font: *const Font,
    size: f32,
};

/// The styled font and size of a line's first glyph (or of the style before it).
fn lineFont(w: *const Work, l: LineInfo) ?LineFont {
    if (l.end > l.start) {
        const g = w.shaped.items[l.start];
        return .{
            .font = g.primary,
            .size = w.out.styles.items[g.style].size,
        };
    }
    const st_i: u32 = if (l.start > 0) w.shaped.items[l.start - 1].style else 0;
    if (w.out.styles.items.len == 0) return null;
    const st = w.out.styles.items[st_i];
    return .{
        .font = st.font orelse return null,
        .size = st.size,
    };
}

/// List indentation per level, in ems of the paragraph's font size.
pub var list_indent: f32 = 1.5;
/// A bullet's centre sits this many ems left of the text.
pub var bullet_centre: f32 = 0.75;
/// A number marker ends this many ems left of the text.
pub var number_gap: f32 = 1.0 / 3.0;

/// Adds a glyph's underline or strikethrough, joining the previous one when it continues
/// it.
fn addDecoration(gpa: std.mem.Allocator, out: *Layout, g: Shaped, st: Resolved, x: f32, adv: f32, baseline: f32) !void {
    const f = g.primary;
    const s = st.size / @as(f32, @floatFromInt(f.units_per_em));
    var top: f32 = undefined;
    var thick: f32 = undefined;
    if (st.decoration == .underline) {
        thick = @as(f32, @floatFromInt(f.underline_thickness)) * s;
        top = baseline - @as(f32, @floatFromInt(f.underline_position)) * s + thick / 2;
    } else {
        thick = @as(f32, @floatFromInt(f.strikeout_size)) * s;
        top = baseline - @as(f32, @floatFromInt(f.strikeout_position)) * s;
    }
    const rect: geom.Rect = .{
        .x0 = x,
        .x1 = x + adv,
        .y0 = top,
        .y1 = top + thick,
    };
    if (out.decorations.items.len > 0) {
        const prev = &out.decorations.items[out.decorations.items.len - 1];
        if (prev.style == g.style and prev.rect.y0 == rect.y0 and prev.rect.y1 == rect.y1 and @abs(prev.rect.x1 - rect.x0) < 1e-3) {
            prev.rect.x1 = rect.x1;
            return;
        }
    }
    try out.decorations.append(gpa, .{
        .rect = rect,
        .style = g.style,
    });
}

/// Underlines skip ink: Figma leaves gaps where glyphs cross them.
pub var skip_ink = true;
/// The band searched for ink reaches this many underline thicknesses above and below it.
pub var skip_ink_band: f32 = 0;
/// Each gap reaches this many underline thicknesses past the ink.
pub var skip_ink_pad: f32 = 1;

/// Cuts the underlines from `from` on where the line's glyphs have ink in or near them.
fn skipInk(gpa: std.mem.Allocator, out: *Layout, from: usize, glyphs: []const Placed) !void {
    if (!skip_ink) return;
    var path: geom.Path = .{};
    defer path.deinit(gpa);
    var polys: geom.Polylines = .{};
    defer polys.deinit(gpa);
    var gaps: std.ArrayList([2]f32) = .empty;
    defer gaps.deinit(gpa);
    var d: usize = from;
    while (d < out.decorations.items.len) {
        const deco = out.decorations.items[d];
        if (out.styles.items[deco.style].decoration != .underline) {
            d += 1;
            continue;
        }
        const thick = deco.rect.y1 - deco.rect.y0;
        const y0 = deco.rect.y0 - skip_ink_band * thick;
        const y1 = deco.rect.y1 + skip_ink_band * thick;
        gaps.clearRetainingCapacity();
        for (glyphs) |g| {
            if (g.cos != 1) continue;
            const b = g.font.glyphBounds(g.glyph) orelse continue;
            const s = g.size / @as(f32, @floatFromInt(g.font.units_per_em));
            // Quick reject: the glyph's box misses the band or the stroke.
            if (g.y - @as(f32, @floatFromInt(b[1])) * s < y0 or g.y - @as(f32, @floatFromInt(b[3])) * s > y1) continue;
            if (g.x + @as(f32, @floatFromInt(b[2])) * s < deco.rect.x0 - thick or g.x + @as(f32, @floatFromInt(b[0])) * s > deco.rect.x1 + thick) continue;
            path.verbs.clearRetainingCapacity();
            path.points.clearRetainingCapacity();
            try g.font.outline(gpa, g.glyph, .{
                .a = s,
                .d = -s,
                .e = g.x,
                .f = g.y,
            }, &path);
            polys.clear();
            try path.flatten(gpa, 0.02, &polys);
            try inkSpans(gpa, &polys, y0, y1, &gaps);
        }
        if (gaps.items.len == 0) {
            d += 1;
            continue;
        }
        std.mem.sort([2]f32, gaps.items, {}, struct {
            fn lt(_: void, a: [2]f32, b: [2]f32) bool {
                return a[0] < b[0];
            }
        }.lt);
        // Replace the stroke by the pieces between the padded gaps.
        const pad = skip_ink_pad * thick;
        var x = deco.rect.x0;
        var pieces: std.ArrayList(Decoration) = .empty;
        defer pieces.deinit(gpa);
        for (gaps.items) |gp| {
            const a = gp[0] - pad;
            const b = gp[1] + pad;
            if (a > x) try pieces.append(gpa, .{
                .rect = .{
                    .x0 = x,
                    .x1 = @min(a, deco.rect.x1),
                    .y0 = deco.rect.y0,
                    .y1 = deco.rect.y1,
                },
                .style = deco.style,
            });
            x = @max(x, b);
            if (x >= deco.rect.x1) break;
        }
        if (x < deco.rect.x1) try pieces.append(gpa, .{
            .rect = .{
                .x0 = x,
                .x1 = deco.rect.x1,
                .y0 = deco.rect.y0,
                .y1 = deco.rect.y1,
            },
            .style = deco.style,
        });
        _ = out.decorations.orderedRemove(d);
        try out.decorations.insertSlice(gpa, d, pieces.items);
        d += pieces.items.len;
    }
}

/// The x spans where a filled outline has ink between `y0` and `y1`: filled spans on
/// scanlines through the band plus every edge piece inside it.
fn inkSpans(gpa: std.mem.Allocator, polys: *const geom.Polylines, y0: f32, y1: f32, out: *std.ArrayList([2]f32)) !void {
    const n_scan = 16;
    var xs: std.ArrayList([2]f32) = .empty; // x, winding direction
    defer xs.deinit(gpa);
    var k: u32 = 0;
    while (k <= n_scan) : (k += 1) {
        const y = y0 + (y1 - y0) * @as(f32, @floatFromInt(k)) / n_scan;
        xs.clearRetainingCapacity();
        for (polys.contours.items) |c| {
            const p = polys.contour(c);
            for (p, 0..) |a, i| {
                const b = p[(i + 1) % p.len];
                if ((a.y <= y) == (b.y <= y)) continue;
                const x = a.x + (y - a.y) / (b.y - a.y) * (b.x - a.x);
                try xs.append(gpa, .{ x, if (b.y > a.y) 1 else -1 });
            }
        }
        std.mem.sort([2]f32, xs.items, {}, struct {
            fn lt(_: void, a: [2]f32, b: [2]f32) bool {
                return a[0] < b[0];
            }
        }.lt);
        var wind: f32 = 0;
        var span_start: f32 = 0;
        for (xs.items) |e| {
            const before = wind;
            wind += e[1];
            if (before == 0 and wind != 0) span_start = e[0];
            if (before != 0 and wind == 0) try out.append(gpa, .{ span_start, e[0] });
        }
    }
    for (polys.contours.items) |c| {
        const p = polys.contour(c);
        for (p, 0..) |a, i| {
            const b = p[(i + 1) % p.len];
            const lo = @max(@min(a.y, b.y), y0);
            const hi = @min(@max(a.y, b.y), y1);
            if (lo > hi) continue;
            // The edge's x range within the band.
            const xa = if (b.y == a.y) a.x else a.x + (lo - a.y) / (b.y - a.y) * (b.x - a.x);
            const xb = if (b.y == a.y) b.x else a.x + (hi - a.y) / (b.y - a.y) * (b.x - a.x);
            try out.append(gpa, .{ @min(xa, xb), @max(xa, xb) });
        }
    }
}

const LineMetrics = struct {
    height: f32,
    ascent: f32,
};

fn lineMetrics(f: *const Font, st: Resolved) LineMetrics {
    const upem: f32 = @floatFromInt(f.units_per_em);
    const asc: f32 = @floatFromInt(if (f.use_typo_metrics) f.typo_ascender else f.ascender);
    const desc: f32 = @floatFromInt(if (f.use_typo_metrics) f.typo_descender else f.descender);
    const gap: f32 = @floatFromInt(if (f.use_typo_metrics) f.typo_line_gap else f.line_gap);
    const s = st.size / upem;
    const natural = (asc - desc + gap) * s;
    const h: f32 = switch (st.line_height) {
        .auto => natural,
        .px => |v| v,
        .percent => |p| p / 100 * st.size,
    };
    // Figma steps lines by the rounded line height and centres the glyphs in it, with the
    // baseline snapped to a whole pixel.
    const pitch = @round(h);
    const content = (asc - desc) * s;
    return .{
        .height = pitch,
        .ascent = @round((pitch - content) / 2 + asc * s),
    };
}

/// Glyph advances are kept to this many steps per pixel (0: exact), and how.
pub var advance_steps: f32 = 0;
pub var advance_floor: bool = false;

/// Figma keeps glyph metrics on a 1024-units-per-em grid: the advance and the shaping
/// adjustment (kerning) are each rounded to it, apart (measured: IBM Plex Mono's 600/1000
/// em advance lays out at 614/1024).
fn gridAdvance(font: *const Font, g: shape_mod.Glyph) f32 {
    const base: i32 = font.advance(g.id);
    return unitsAdvance(base, font.units_per_em) + unitsAdvance(g.x_advance - base, font.units_per_em);
}

/// Re-expresses an advance in `advance_upem` units (rounded or floored) when set, as a font
/// pipeline that converts fonts to one unit grid would.
pub var advance_upem: f32 = 1024;
pub var advance_upem_floor: bool = false;

fn unitsAdvance(adv: i32, upem: u16) f32 {
    const a: f32 = @floatFromInt(adv);
    const u: f32 = @floatFromInt(upem);
    if (advance_upem <= 0 or u == advance_upem) return a;
    const v = a * advance_upem / u;
    const q = if (advance_upem_floor) @floor(v) else @round(v);
    return q * u / advance_upem;
}

fn quantize(v: f32) f32 {
    if (advance_steps <= 0) return v;
    return if (advance_floor) @floor(v * advance_steps) / advance_steps else @round(v * advance_steps) / advance_steps;
}

/// Synthesised small capitals: capitals scaled down, with a little extra tracking
/// (measured against Figma's renders of fonts without `smcp`).
pub var small_caps_scale: f32 = 0.85;
/// Extra space after each synthesised small capital, in ems of the style's size.
pub var small_caps_tracking: f32 = 0.042;

/// When a font has no small capitals of its own, small-caps text uses scaled capitals:
/// lowercase letters (and with "forced", capitals too).
fn synthesiseSmallCaps(chars: []Char, styles: []const Resolved) void {
    for (chars) |*c| {
        const st = styles[c.style];
        if (st.case != .small_caps and st.case != .small_caps_forced) continue;
        const font = st.font orelse continue;
        if (font.hasFeature("smcp".*)) continue;
        const is_lower = lower(c.cp) == c.cp and upper(c.cp) != c.cp;
        const is_upper = upper(c.cp) == c.cp and lower(c.cp) != c.cp;
        if (is_lower or (st.case == .small_caps_forced and is_upper)) {
            c.cp = upper(c.cp);
            c.synth = true;
        } else if (st.case == .small_caps_forced) {
            // Punctuation and digits follow the letters around them.
            c.synth = true;
        }
    }
}

/// Characters the styled font has no glyph for are drawn from the first fallback font that
/// has one (spaces and controls stay with the styled font).
fn assignFallbacks(chars: []Char, styles: []const Resolved, fonts: *const FontSet) void {
    if (fonts.fallbacks.items.len == 0) return;
    for (chars) |*c| {
        if (c.cp <= ' ' or isBreak(c.cp)) continue;
        const font = styles[c.style].font orelse continue;
        if (font.glyphIndex(c.cp) != 0) continue;
        for (fonts.fallbacks.items) |f| {
            if (f.glyphIndex(c.cp) != 0) {
                c.fallback = f;
                break;
            }
        }
    }
}

fn appendUtf8(gpa: std.mem.Allocator, out: *std.ArrayList(u8), cp: u21) !void {
    var b: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &b) catch 1;
    try out.appendSlice(gpa, b[0..n]);
}

/// Line separator, paragraph separator and newline end a line.
fn isBreak(cp: u21) bool {
    return cp == '\n' or cp == 0x2028 or cp == 0x2029 or cp == '\r';
}

/// Newline and paragraph separator end a paragraph (a line separator does not).
fn isParaBreak(cp: u21) bool {
    return cp == '\n' or cp == 0x2029 or cp == '\r';
}

/// Opening punctuation that hangs outside the box when it starts a line.
fn isHanging(cp: u21) bool {
    return switch (cp) {
        '"', '\'', '(', '[', '{', 0xAB, 0xBB, 0x2018, 0x201A, 0x201B, 0x201C, 0x201E, 0x201F, 0x2039, 0x203A => true,
        else => false,
    };
}

/// Upper, lower and title case change the characters themselves (before shaping).
fn applyCase(chars: []Char, styles: []const Resolved) void {
    var word_start = true;
    for (chars) |*c| {
        const st = styles[c.style];
        const is_letter = c.cp < 128 and std.ascii.isAlphanumeric(@intCast(c.cp));
        switch (st.case) {
            .upper => c.cp = upper(c.cp),
            .lower => c.cp = lower(c.cp),
            .title => if (word_start) {
                c.cp = upper(c.cp);
            },
            else => {},
        }
        word_start = !(is_letter or c.cp == '\'' or c.cp == 0x2019 or (c.cp >= 0xC0 and c.cp < 0x250));
    }
}

fn upper(cp: u21) u21 {
    if (cp < 128) return std.ascii.toUpper(@intCast(cp));
    if ((cp >= 0xE0 and cp <= 0xFE and cp != 0xF7)) return cp - 0x20;
    if (cp >= 0x100 and cp < 0x180 and cp % 2 == 1) return cp - 1;
    return cp;
}

fn lower(cp: u21) u21 {
    if (cp < 128) return std.ascii.toLower(@intCast(cp));
    if ((cp >= 0xC0 and cp <= 0xDE and cp != 0xD7)) return cp + 0x20;
    if (cp >= 0x100 and cp < 0x180 and cp % 2 == 0) return cp + 1;
    return cp;
}

fn testFonts(arena: std.mem.Allocator, set: *FontSet) !void {
    const bytes = try font_mod.testFont(arena, "Inter-Regular.ttf");
    const f = try Font.parse(arena, bytes);
    try set.faces.append(arena, .{
        .family = "Inter",
        .style = "Regular",
        .weight = 400,
        .italic = false,
        .font = f,
    });
}

test "justified lines reach the box edge; the last line does not" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var set: FontSet = .{};
    try testFonts(arena.allocator(), &set);
    const t: m.Text = .{
        .text = "Design has many layers. A clear specimen lets you compare each setting.",
        .style = .{
            .family = "Inter",
            .size = 22,
        },
        .@"align" = .justify,
        .resize = .height,
    };
    var lay = try layout(
        std.testing.allocator,
        &t,
        .{
            .x = 352,
            .y = 81,
        },
        &set,
        .{},
    );
    defer lay.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), lay.lines.items.len);
    // The first line's last glyph (not the hanging space) ends at the box edge.
    const space = set.faces.items[0].font.glyphIndex(' ');
    var last_x: f32 = 0;
    var last: ?Placed = null;
    for (lay.glyphs.items) |g| if (g.y == lay.lines.items[0].baseline and g.x >= last_x and g.glyph != space) {
        last_x = g.x;
        last = g;
    };
    const g = last.?;
    const end = g.x + @as(f32, @floatFromInt(g.font.advance(g.glyph))) * 22 / @as(f32, @floatFromInt(g.font.units_per_em));
    try std.testing.expectApproxEqAbs(@as(f32, 352), end, 0.01);
}

test "truncation keeps the lines that fit and ends in an ellipsis" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var set: FontSet = .{};
    try testFonts(arena.allocator(), &set);
    const t: m.Text = .{
        .text = "Design has many layers. Long copy reveals truncation, wrapping, and the last visible line of this specimen.",
        .style = .{
            .family = "Inter",
            .size = 22,
        },
        .resize = .truncate,
        .truncation = .ending,
    };
    var lay = try layout(
        std.testing.allocator,
        &t,
        .{
            .x = 270,
            .y = 100,
        },
        &set,
        .{},
    );
    defer lay.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), lay.lines.items.len);
    const ell = set.faces.items[0].font.glyphIndex(0x2026);
    try std.testing.expectEqual(ell, lay.glyphs.items[lay.glyphs.items.len - 1].glyph);
}

test "list markers and balanced lines" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var set: FontSet = .{};
    try testFonts(arena.allocator(), &set);
    var lists = [_]m.ParagraphList{
        .{
            .type = .unordered,
            .indent = 1,
        },
        .{
            .type = .unordered,
            .indent = 1,
        },
    };
    const t: m.Text = .{
        .text = "Research\nDesign",
        .style = .{
            .family = "Inter",
            .size = 20,
        },
        .lists = &lists,
    };
    var lay = try layout(
        std.testing.allocator,
        &t,
        .{
            .x = 352,
            .y = 48,
        },
        &set,
        .{},
    );
    defer lay.deinit(std.testing.allocator);
    const bullet = set.faces.items[0].font.glyphIndex(0x2022);
    var bullets: u32 = 0;
    for (lay.glyphs.items) |g| {
        if (g.glyph == bullet) bullets += 1;
    }
    try std.testing.expectEqual(@as(u32, 2), bullets);

    const b: m.Text = .{
        .text = "A useful design reference explains the setting and shows an editable example.",
        .style = .{
            .family = "Inter",
            .size = 22,
        },
        .wrap = .balance,
    };
    var bal = try layout(
        std.testing.allocator,
        &b,
        .{
            .x = 352,
            .y = 81,
        },
        &set,
        .{},
    );
    defer bal.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), bal.lines.items.len);
    for (bal.lines.items) |l| try std.testing.expect(l.width < 300);
}
