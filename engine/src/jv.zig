//! Reading values out of parsed JSON without ceremony.

const std = @import("std");

pub const Value = std.json.Value;

pub fn get(v: Value, key: []const u8) ?Value {
    if (v != .object) return null;
    return v.object.get(key);
}

pub fn str(v: Value, key: []const u8) ?[]const u8 {
    const x = get(v, key) orelse return null;
    return if (x == .string) x.string else null;
}

pub fn boolean(v: Value, key: []const u8) ?bool {
    const x = get(v, key) orelse return null;
    return if (x == .bool) x.bool else null;
}

pub fn num(v: Value, key: []const u8) ?f32 {
    return numberOf(get(v, key) orelse return null);
}

pub fn numberOf(x: Value) ?f32 {
    return switch (x) {
        .integer => |i| @floatFromInt(i),
        .float => |f| @floatCast(f),
        .number_string => |s| std.fmt.parseFloat(f32, s) catch null,
        else => null,
    };
}

pub fn arr(v: Value, key: []const u8) []const Value {
    const x = get(v, key) orelse return &.{};
    return if (x == .array) x.array.items else &.{};
}
