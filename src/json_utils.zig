const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Value = std.json.Value;
pub const ObjectMap = std.json.ObjectMap;

/// Get a string value from a JSON object by key.
pub fn getString(obj: ObjectMap, key: []const u8) ?[]const u8 {
    const val = obj.get(key) orelse return null;
    return switch (val) {
        .string => |s| s,
        else => null,
    };
}

/// Get an integer value from a JSON object by key.
pub fn getInteger(obj: ObjectMap, key: []const u8) ?i64 {
    const val = obj.get(key) orelse return null;
    return switch (val) {
        .integer => |i| i,
        else => null,
    };
}

/// Get an unsigned integer value from a JSON object by key.
pub fn getUnsigned(obj: ObjectMap, key: []const u8) ?u64 {
    const val = obj.get(key) orelse return null;
    return switch (val) {
        .integer => |i| if (i >= 0) @as(u64, @intCast(i)) else null,
        else => null,
    };
}

/// Get an object value from a JSON object by key.
pub fn getObject(obj: ObjectMap, key: []const u8) ?ObjectMap {
    const val = obj.get(key) orelse return null;
    return switch (val) {
        .object => |o| o,
        else => null,
    };
}

/// Get an array value from a JSON object by key.
pub fn getArray(obj: ObjectMap, key: []const u8) ?[]Value {
    const val = obj.get(key) orelse return null;
    return switch (val) {
        .array => |a| a.items,
        else => null,
    };
}

/// Stringify a JSON value to a std.io.Writer.
pub fn stringifyToWriter(value: Value, w: *std.io.Writer) !void {
    try std.json.Stringify.value(value, .{}, w);
}

/// Stringify a JSON value to an allocated string.
pub fn stringifyAlloc(allocator: Allocator, value: Value) ![]const u8 {
    var aw: std.io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    try stringifyToWriter(value, &aw.writer);
    return aw.toOwnedSlice();
}

/// Parse a JSON string into a Value.
pub fn parse(allocator: Allocator, input: []const u8) !std.json.Parsed(Value) {
    return std.json.parseFromSlice(Value, allocator, input, .{});
}

/// Create a JSON string value.
pub fn jsonString(s: []const u8) Value {
    return .{ .string = s };
}

/// Create a JSON integer value.
pub fn jsonInteger(i: i64) Value {
    return .{ .integer = i };
}

/// Create a JSON boolean value.
pub fn jsonBool(b: bool) Value {
    return if (b) .{ .bool = true } else .{ .bool = false };
}

test "getString" {
    var obj = ObjectMap.init(std.testing.allocator);
    defer obj.deinit();
    try obj.put("key", .{ .string = "value" });
    try std.testing.expectEqualStrings("value", getString(obj, "key").?);
    try std.testing.expect(getString(obj, "missing") == null);
}

test "getInteger" {
    var obj = ObjectMap.init(std.testing.allocator);
    defer obj.deinit();
    try obj.put("num", .{ .integer = 42 });
    try std.testing.expectEqual(@as(i64, 42), getInteger(obj, "num").?);
    try std.testing.expect(getInteger(obj, "missing") == null);
}
