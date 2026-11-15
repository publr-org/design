//! A general reader for Kiwi, the open binary message format (github.com/evanw/kiwi, MIT).
//!
//! A Kiwi file carries its schema: a list of definitions (enums, structs, messages), each
//! with typed fields. `parseSchema` reads one; `decode` reads a value of any definition
//! into a generic tree; `View` walks that tree by field name.
//!
//! Encoding, from the public spec:
//! - `uint`: LEB128 varint (7 bits a byte, low first); `int`: the uint zigzag-decoded.
//! - `int64`/`uint64`: the same with up to 10 bytes.
//! - `float`: one byte 0 means 0.0; else four bytes, little-endian, holding the f32 bits
//!   rotated left by 9 (`bits = (raw << 23) | (raw >> 9)` undoes it).
//! - `bool`, `byte`: one byte. `string`: UTF-8, null-terminated.
//! - An array: a uint count, then the elements; `byte[]` is a count then raw bytes.
//! - An enum: a uint value. A struct: every field in order. A message: (field id, value)
//!   pairs, ended by id 0; fields may be left out.
//!
//! The schema itself: a uint definition count; each definition is a name (string), a kind
//! byte (0 enum, 1 struct, 2 message), a uint field count and the fields: a name, a type
//! (an int: -1 bool, -2 byte, -3 int, -4 uint, -5 float, -6 string, -7 int64, -8 uint64,
//! or the index of a definition), an is-array byte and a uint value (the enum value or the
//! message field id).
//!
//! Every read is bounds-checked and nesting is limited: corrupt input is an error, never a
//! crash.

const std = @import("std");

pub const Error = error{
    /// The bytes end before the value does, or a count runs past them.
    Truncated,
    /// A definition, type, field id or enum value that the schema does not allow.
    BadSchema,
    /// A field id the definition does not have.
    UnknownField,
    /// Values nest deeper than `max_depth`.
    TooDeep,
    OutOfMemory,
};

/// The deepest nesting `decode` follows.
pub const max_depth = 64;

pub const Kind = enum(u8) {
    @"enum" = 0,
    @"struct" = 1,
    message = 2,
};

/// A primitive type or a definition.
pub const Type = union(enum) {
    bool,
    byte,
    int,
    uint,
    float,
    string,
    int64,
    uint64,
    def: u32,
};

pub const Field = struct {
    name: []const u8,
    type: Type,
    is_array: bool,
    /// Enum value, or message field id.
    value: u32,
};

pub const Def = struct {
    name: []const u8,
    kind: Kind,
    fields: []Field,
    /// Message field id to field index (+1; 0 = none), for ids below its length.
    by_id: []u16 = &.{},

    /// The field with message id `id`.
    pub fn fieldById(self: *const Def, id: u32) ?u32 {
        if (id < self.by_id.len) {
            const k = self.by_id[id];
            return if (k == 0) null else k - 1;
        }
        for (self.fields, 0..) |f, i| if (f.value == id) return @intCast(i);
        return null;
    }

    pub fn fieldByName(self: *const Def, name: []const u8) ?u32 {
        for (self.fields, 0..) |f, i| if (std.mem.eql(u8, f.name, name)) return @intCast(i);
        return null;
    }

    /// The name of enum value `v`.
    pub fn enumName(self: *const Def, v: u32) ?[]const u8 {
        for (self.fields) |f| if (f.value == v) return f.name;
        return null;
    }
};

pub const Schema = struct {
    defs: []Def,

    pub fn find(self: *const Schema, name: []const u8) ?u32 {
        for (self.defs, 0..) |d, i| if (std.mem.eql(u8, d.name, name)) return @intCast(i);
        return null;
    }
};

/// A decoded value. Strings and byte arrays point into the decoded bytes.
pub const Value = union(enum) {
    bool: bool,
    byte: u8,
    int: i32,
    uint: u32,
    float: f32,
    string: []const u8,
    int64: i64,
    uint64: u64,
    /// A `byte[]`.
    bytes: []const u8,
    array: []const Value,
    @"enum": Enum,
    /// A struct or a message: the fields present, in the order read.
    record: Record,
};

pub const Enum = struct {
    def: u32,
    value: u32,
};

pub const Record = struct {
    def: u32,
    entries: []const Entry,
};

pub const Entry = struct {
    /// Index into the definition's fields.
    field: u32,
    value: Value,
};

/// A bounded little reader over bytes.
pub const Reader = struct {
    bytes: []const u8,
    at: usize = 0,

    pub fn remaining(r: *const Reader) usize {
        return r.bytes.len - r.at;
    }

    pub fn byte(r: *Reader) Error!u8 {
        if (r.at >= r.bytes.len) return error.Truncated;
        defer r.at += 1;
        return r.bytes[r.at];
    }

    pub fn varUint(r: *Reader) Error!u32 {
        var v: u32 = 0;
        var shift: u5 = 0;
        while (true) {
            const c = try r.byte();
            v |= @as(u32, c & 127) << shift;
            if (c < 128 or shift >= 28) return v;
            shift += 7;
        }
    }

    pub fn varInt(r: *Reader) Error!i32 {
        const v = try r.varUint();
        return @bitCast((v >> 1) ^ (0 -% (v & 1)));
    }

    pub fn varUint64(r: *Reader) Error!u64 {
        var v: u64 = 0;
        var shift: u6 = 0;
        while (true) {
            const c = try r.byte();
            v |= @as(u64, c & 127) << shift;
            if (c < 128 or shift >= 63) return v;
            shift += 7;
        }
    }

    pub fn varInt64(r: *Reader) Error!i64 {
        const v = try r.varUint64();
        return @bitCast((v >> 1) ^ (0 -% (v & 1)));
    }

    pub fn float(r: *Reader) Error!f32 {
        const first = try r.byte();
        if (first == 0) return 0;
        if (r.remaining() < 3) return error.Truncated;
        const raw = @as(u32, first) | @as(u32, r.bytes[r.at]) << 8 | @as(u32, r.bytes[r.at + 1]) << 16 | @as(u32, r.bytes[r.at + 2]) << 24;
        r.at += 3;
        return @bitCast((raw << 23) | (raw >> 9));
    }

    pub fn string(r: *Reader) Error![]const u8 {
        const end = std.mem.indexOfScalarPos(u8, r.bytes, r.at, 0) orelse return error.Truncated;
        defer r.at = end + 1;
        return r.bytes[r.at..end];
    }

    pub fn slice(r: *Reader, n: usize) Error![]const u8 {
        if (n > r.remaining()) return error.Truncated;
        defer r.at += n;
        return r.bytes[r.at..][0..n];
    }
};

/// Reads a binary schema. Names point into `bytes`.
pub fn parseSchema(a: std.mem.Allocator, bytes: []const u8) Error!Schema {
    var r: Reader = .{
        .bytes = bytes,
    };
    const count = try r.varUint();
    if (count > r.remaining()) return error.Truncated;
    const defs = try a.alloc(Def, count);
    for (defs) |*d| {
        const name = try r.string();
        const kind = std.enums.fromInt(Kind, try r.byte()) orelse return error.BadSchema;
        const n = try r.varUint();
        if (n > r.remaining()) return error.Truncated;
        const fields = try a.alloc(Field, n);
        for (fields) |*f| {
            const fname = try r.string();
            const t = try r.varInt();
            const is_array = (try r.byte()) != 0;
            const value = try r.varUint();
            f.* = .{
                .name = fname,
                .type = switch (t) {
                    -1 => .bool,
                    -2 => .byte,
                    -3 => .int,
                    -4 => .uint,
                    -5 => .float,
                    -6 => .string,
                    -7 => .int64,
                    -8 => .uint64,
                    else => if (t >= 0 and t < count) .{
                        .def = @intCast(t),
                    } else return error.BadSchema,
                },
                .is_array = is_array,
                .value = value,
            };
        }
        d.* = .{
            .name = name,
            .kind = kind,
            .fields = fields,
        };
        if (kind == .message) {
            var max: u32 = 0;
            for (fields) |f| max = @max(max, f.value);
            if (max < 4096) {
                const by_id = try a.alloc(u16, max + 1);
                @memset(by_id, 0);
                for (fields, 0..) |f, i| by_id[f.value] = @intCast(i + 1);
                d.by_id = by_id;
            }
        }
    }
    return .{
        .defs = defs,
    };
}

/// Decodes one value of definition `root` from `bytes`. The tree lives in `a`; strings
/// and byte arrays point into `bytes`.
pub fn decode(a: std.mem.Allocator, schema: *const Schema, root: u32, bytes: []const u8) Error!Value {
    if (root >= schema.defs.len) return error.BadSchema;
    var d: Decoder = .{
        .a = a,
        .s = schema,
        .r = .{
            .bytes = bytes,
        },
    };
    return d.def(root, 0);
}

/// Decodes one value of definition `def` starting at byte `at` of `bytes` (a value
/// whose place `skip` found), the tree in `a`.
pub fn decodeAt(a: std.mem.Allocator, schema: *const Schema, def: u32, bytes: []const u8, at: usize) Error!Value {
    if (def >= schema.defs.len) return error.BadSchema;
    var d: Decoder = .{
        .a = a,
        .s = schema,
        .r = .{
            .bytes = bytes,
            .at = at,
        },
    };
    return d.def(def, 0);
}

/// Decodes field `f`'s value at the reader (for walking a message by hand).
pub fn decodeField(a: std.mem.Allocator, schema: *const Schema, f: Field, r: *Reader) Error!Value {
    var d: Decoder = .{
        .a = a,
        .s = schema,
        .r = r.*,
    };
    defer r.* = d.r;
    return d.field(f, 0);
}

/// Moves the reader past one value of type `t` without building it: how a large message
/// is indexed (where each element starts) and read later a piece at a time.
pub fn skip(schema: *const Schema, t: Type, r: *Reader) Error!void {
    return skipDepth(schema, t, r, 0);
}

/// Moves the reader past field `f`'s value (an array: all its elements).
pub fn skipField(schema: *const Schema, f: Field, r: *Reader) Error!void {
    return skipFieldDepth(schema, f, r, 0);
}

fn skipDepth(schema: *const Schema, t: Type, r: *Reader, depth: u32) Error!void {
    if (depth > max_depth) return error.TooDeep;
    switch (t) {
        .bool, .byte => _ = try r.byte(),
        .int, .uint => _ = try r.varUint(),
        .float => _ = try r.float(),
        .string => _ = try r.string(),
        .int64, .uint64 => _ = try r.varUint64(),
        .def => |index| {
            if (index >= schema.defs.len) return error.BadSchema;
            const df = &schema.defs[index];
            switch (df.kind) {
                .@"enum" => _ = try r.varUint(),
                .@"struct" => for (df.fields) |f| try skipFieldDepth(schema, f, r, depth),
                .message => while (true) {
                    const id = try r.varUint();
                    if (id == 0) break;
                    const fi = df.fieldById(id) orelse return error.UnknownField;
                    try skipFieldDepth(schema, df.fields[fi], r, depth);
                },
            }
        },
    }
}

fn skipFieldDepth(schema: *const Schema, f: Field, r: *Reader, depth: u32) Error!void {
    if (!f.is_array) return skipDepth(schema, f.type, r, depth + 1);
    const n = try r.varUint();
    if (f.type == .byte) {
        _ = try r.slice(n);
        return;
    }
    const empty_struct = f.type == .def and schema.defs[f.type.def].kind == .@"struct" and schema.defs[f.type.def].fields.len == 0;
    if (n > r.remaining() and !(empty_struct and n <= 1 << 16)) return error.Truncated;
    for (0..n) |_| try skipDepth(schema, f.type, r, depth + 1);
}

const Decoder = struct {
    a: std.mem.Allocator,
    s: *const Schema,
    r: Reader,
    /// A message's fields as they are read, before it knows how many it has: shared by
    /// nested messages (each takes the top), then copied out at its exact size, so no
    /// list grows in `a` (an arena keeps every outgrown buffer).
    stack: []Entry = &.{},
    top: usize = 0,

    fn push(d: *Decoder, e: Entry) Error!void {
        if (d.top == d.stack.len) {
            const bigger = try d.a.alloc(Entry, @max(64, d.stack.len * 2));
            @memcpy(bigger[0..d.top], d.stack[0..d.top]);
            d.a.free(d.stack);
            d.stack = bigger;
        }
        d.stack[d.top] = e;
        d.top += 1;
    }

    fn def(d: *Decoder, index: u32, depth: u32) Error!Value {
        if (depth > max_depth) return error.TooDeep;
        const df = &d.s.defs[index];
        switch (df.kind) {
            .@"enum" => {
                const v = try d.r.varUint();
                return .{
                    .@"enum" = .{
                        .def = index,
                        .value = v,
                    },
                };
            },
            .@"struct" => {
                const entries = try d.a.alloc(Entry, df.fields.len);
                for (entries, df.fields, 0..) |*e, f, i| e.* = .{
                    .field = @intCast(i),
                    .value = try d.field(f, depth),
                };
                return .{
                    .record = .{
                        .def = index,
                        .entries = entries,
                    },
                };
            },
            .message => {
                const start = d.top;
                defer d.top = start;
                while (true) {
                    const id = try d.r.varUint();
                    if (id == 0) break;
                    const fi = df.fieldById(id) orelse return error.UnknownField;
                    const value = try d.field(df.fields[fi], depth);
                    try d.push(.{
                        .field = fi,
                        .value = value,
                    });
                }
                return .{
                    .record = .{
                        .def = index,
                        .entries = try d.a.dupe(Entry, d.stack[start..d.top]),
                    },
                };
            },
        }
    }

    fn field(d: *Decoder, f: Field, depth: u32) Error!Value {
        if (!f.is_array) return d.one(f.type, depth + 1);
        const n = try d.r.varUint();
        if (f.type == .byte) return .{
            .bytes = try d.r.slice(n),
        };
        // Every element takes at least a byte, except a struct with no fields.
        const empty_struct = f.type == .def and d.s.defs[f.type.def].kind == .@"struct" and d.s.defs[f.type.def].fields.len == 0;
        if (n > d.r.remaining() and !(empty_struct and n <= 1 << 16)) return error.Truncated;
        const items = try d.a.alloc(Value, n);
        for (items) |*it| it.* = try d.one(f.type, depth + 1);
        return .{
            .array = items,
        };
    }

    fn one(d: *Decoder, t: Type, depth: u32) Error!Value {
        return switch (t) {
            .bool => .{
                .bool = (try d.r.byte()) != 0,
            },
            .byte => .{
                .byte = try d.r.byte(),
            },
            .int => .{
                .int = try d.r.varInt(),
            },
            .uint => .{
                .uint = try d.r.varUint(),
            },
            .float => .{
                .float = try d.r.float(),
            },
            .string => .{
                .string = try d.r.string(),
            },
            .int64 => .{
                .int64 = try d.r.varInt64(),
            },
            .uint64 => .{
                .uint64 = try d.r.varUint64(),
            },
            .def => |i| d.def(i, depth),
        };
    }
};

/// A value with its schema, for reading fields by name. Every accessor returns null when
/// the field is absent or of another type, so callers never trust the file's shape.
pub const View = struct {
    s: *const Schema,
    v: Value,

    /// The field `name` of a record (for messages: when present).
    pub fn get(self: View, name: []const u8) ?View {
        if (self.v != .record) return null;
        const df = &self.s.defs[self.v.record.def];
        for (self.v.record.entries) |e| {
            if (std.mem.eql(u8, df.fields[e.field].name, name)) return .{
                .s = self.s,
                .v = e.value,
            };
        }
        return null;
    }

    /// Follows dotted field names: `"parentIndex.guid"`.
    pub fn path(self: View, dotted: []const u8) ?View {
        var cur = self;
        var it = std.mem.splitScalar(u8, dotted, '.');
        while (it.next()) |name| cur = cur.get(name) orelse return null;
        return cur;
    }

    /// The name of the record's definition.
    pub fn typeName(self: View) ?[]const u8 {
        return switch (self.v) {
            .record => |r| self.s.defs[r.def].name,
            .@"enum" => |e| self.s.defs[e.def].name,
            else => null,
        };
    }

    pub fn has(self: View, name: []const u8) bool {
        return self.get(name) != null;
    }

    /// The value as a number. A float that is not finite (NaN, ±inf) reads as absent:
    /// files store NaN where a value is unknown, such as the size of a group whose
    /// children are all hidden (docs/fig-format.md, "Numbers that are not numbers").
    pub fn float(self: View) ?f32 {
        return switch (self.v) {
            .float => |f| if (std.math.isFinite(f)) f else null,
            .int => |i| @floatFromInt(i),
            .uint => |u| @floatFromInt(u),
            .byte => |b| @floatFromInt(b),
            else => null,
        };
    }

    pub fn uint(self: View) ?u32 {
        return switch (self.v) {
            .uint => |u| u,
            .byte => |b| b,
            .int => |i| if (i >= 0) @intCast(i) else null,
            else => null,
        };
    }

    pub fn int(self: View) ?i32 {
        return switch (self.v) {
            .int => |i| i,
            .uint => |u| if (u <= std.math.maxInt(i32)) @intCast(u) else null,
            .byte => |b| b,
            else => null,
        };
    }

    pub fn boolean(self: View) ?bool {
        return switch (self.v) {
            .bool => |b| b,
            else => null,
        };
    }

    pub fn str(self: View) ?[]const u8 {
        return switch (self.v) {
            .string => |s| s,
            else => null,
        };
    }

    pub fn bytes(self: View) ?[]const u8 {
        return switch (self.v) {
            .bytes => |b| b,
            else => null,
        };
    }

    /// An enum value's name.
    pub fn enumName(self: View) ?[]const u8 {
        return switch (self.v) {
            .@"enum" => |e| self.s.defs[e.def].enumName(e.value),
            else => null,
        };
    }

    /// True when the field is an enum spelled `name`.
    pub fn is(self: View, name: []const u8) bool {
        return std.mem.eql(u8, self.enumName() orelse return false, name);
    }

    /// True when field `name` is an enum spelled `value`.
    pub fn fieldIs(self: View, name: []const u8, value: []const u8) bool {
        return (self.get(name) orelse return false).is(value);
    }

    pub fn len(self: View) usize {
        return switch (self.v) {
            .array => |a| a.len,
            .bytes => |b| b.len,
            else => 0,
        };
    }

    pub fn at(self: View, i: usize) View {
        return .{
            .s = self.s,
            .v = self.v.array[i],
        };
    }

    // Field shortcuts.

    pub fn getFloat(self: View, name: []const u8) ?f32 {
        return (self.get(name) orelse return null).float();
    }

    pub fn getUint(self: View, name: []const u8) ?u32 {
        return (self.get(name) orelse return null).uint();
    }

    pub fn getInt(self: View, name: []const u8) ?i32 {
        return (self.get(name) orelse return null).int();
    }

    pub fn getBool(self: View, name: []const u8) ?bool {
        return (self.get(name) orelse return null).boolean();
    }

    pub fn getStr(self: View, name: []const u8) ?[]const u8 {
        return (self.get(name) orelse return null).str();
    }

    pub fn getEnum(self: View, name: []const u8) ?[]const u8 {
        return (self.get(name) orelse return null).enumName();
    }

    /// The elements of an array field (empty when absent).
    pub fn list(self: View, name: []const u8) Items {
        const f = self.get(name) orelse return .{
            .s = self.s,
            .items = &.{},
        };
        return .{
            .s = self.s,
            .items = if (f.v == .array) f.v.array else &.{},
        };
    }
};

/// The elements of an array, as views.
pub const Items = struct {
    s: *const Schema,
    items: []const Value,

    pub fn len(self: Items) usize {
        return self.items.len;
    }

    pub fn at(self: Items, i: usize) View {
        return .{
            .s = self.s,
            .v = self.items[i],
        };
    }
};

// Tests: a schema and message built by hand, byte by byte.

const test_schema = [_]u8{
    3, // three definitions
    // enum Color { RED = 1; GREEN = 2; }
    'C',
    'o',
    'l',
    'o',
    'r',
    0,
    0,
    2,
    'R',
    'E',
    'D',
    0,
    0,
    0,
    1,
    'G',
    'R',
    'E',
    'E',
    'N',
    0,
    0,
    0,
    2,
    // struct Point { float x; float y; }
    'P',
    'o',
    'i',
    'n',
    't',
    0,
    1,
    2,
    'x', 0,   9,   0,   0, // -5 zigzag = 9
    'y', 0,   9,   0,   0,
    // message Shape { string name = 1; Color color = 2; Point[] points = 3; int z = 4; byte[] data = 5; }
    'S', 'h', 'a', 'p', 'e',
    0,   2,   5,
    'n', 'a', 'm', 'e', 0, 11, 0, 1, // -6 zigzag = 11
    'c', 'o', 'l', 'o', 'r', 0, 0, 0, 2, // def 0
    'p', 'o', 'i', 'n', 't', 's', 0, 2, 1, 3, // def 1 zigzag = 2
    'z', 0, 5, 0, 4, // -3 zigzag = 5
    'd', 'a', 't', 'a', 0, 3, 1, 5, // -2 zigzag = 3
};

test "decode a hand-built message" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const schema = try parseSchema(a, &test_schema);
    try std.testing.expectEqual(@as(usize, 3), schema.defs.len);
    const shape = schema.find("Shape").?;

    // 1.5 as f32 is 0x3fc00000; Kiwi stores it rotated: raw = (bits << 9) | (bits >> 23).
    const bits: u32 = @bitCast(@as(f32, 1.5));
    const raw = (bits << 9) | (bits >> 23);
    const msg = [_]u8{
        1, 'h', 'i', 0, // name
        2, 2, // color GREEN
        3, 2, // two points
        @truncate(raw), @truncate(raw >> 8), @truncate(raw >> 16), @truncate(raw >> 24), 0, // (1.5, 0)
        0, 0, // (0, 0)
        4, 3, // z = -2 (zigzag 3)
        5, 2, 0xaa, 0xbb, // data
        0,
    };
    const v = try decode(a, &schema, shape, &msg);
    const view: View = .{
        .s = &schema,
        .v = v,
    };
    try std.testing.expectEqualStrings("hi", view.getStr("name").?);
    try std.testing.expectEqualStrings("GREEN", view.getEnum("color").?);
    const pts = view.list("points");
    try std.testing.expectEqual(@as(usize, 2), pts.len());
    try std.testing.expectEqual(@as(f32, 1.5), pts.at(0).getFloat("x").?);
    try std.testing.expectEqual(@as(f32, 0), pts.at(1).getFloat("y").?);
    try std.testing.expectEqual(@as(i32, -2), view.getInt("z").?);
    try std.testing.expectEqualSlices(u8, &.{ 0xaa, 0xbb }, view.get("data").?.bytes().?);
    try std.testing.expect(view.get("missing") == null);

    // A float that is not a number is there, but reads as absent.
    const nan_bits: u32 = @bitCast(std.math.nan(f32));
    const nan_raw = (nan_bits << 9) | (nan_bits >> 23);
    const nan_msg = [_]u8{
        3, 1, // one point
        @truncate(nan_raw), @truncate(nan_raw >> 8), @truncate(nan_raw >> 16), @truncate(nan_raw >> 24), 0, // (NaN, 0)
        0,
    };
    const nan_view: View = .{
        .s = &schema,
        .v = try decode(a, &schema, shape, &nan_msg),
    };
    const nan_pt = nan_view.list("points").at(0);
    try std.testing.expect(nan_pt.has("x"));
    try std.testing.expect(nan_pt.getFloat("x") == null);
    try std.testing.expectEqual(@as(f32, 0), nan_pt.getFloat("y").?);

    // Every truncation of the message is an error, never a crash.
    var n: usize = 0;
    while (n < msg.len) : (n += 1) {
        try std.testing.expect(std.meta.isError(decode(a, &schema, shape, msg[0..n])));
    }
    // An unknown field id is an error.
    try std.testing.expectError(error.UnknownField, decode(a, &schema, shape, &.{ 9, 0 }));
    // A count larger than the bytes is caught before allocating.
    try std.testing.expectError(error.Truncated, decode(a, &schema, shape, &.{ 3, 0xff, 0xff, 0xff, 0x0f }));
}

test "corrupt schemas are errors" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var n: usize = 0;
    while (n < test_schema.len) : (n += 1) {
        try std.testing.expect(std.meta.isError(parseSchema(a, test_schema[0..n])));
    }
    // A type index past the definitions.
    var bad = test_schema;
    bad[bad.len - 3] = 0x40;
    try std.testing.expect(std.meta.isError(parseSchema(a, &bad)));
}

test "self-nesting stops at the depth limit" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // message Box { Box inner = 1; }
    const schema_bytes = [_]u8{ 1, 'B', 0, 2, 1, 'i', 0, 0, 0, 1 };
    const schema = try parseSchema(a, &schema_bytes);
    var deep: [400]u8 = undefined;
    @memset(&deep, 1);
    try std.testing.expectError(error.TooDeep, decode(a, &schema, 0, &deep));
}
