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

test "getInteger returns null for wrong type" {
    var obj = ObjectMap.init(std.testing.allocator);
    defer obj.deinit();
    try obj.put("str", .{ .string = "not a number" });
    try std.testing.expect(getInteger(obj, "str") == null);
}

test "getString returns null for wrong type" {
    var obj = ObjectMap.init(std.testing.allocator);
    defer obj.deinit();
    try obj.put("num", .{ .integer = 42 });
    try std.testing.expect(getString(obj, "num") == null);
}

test "getUnsigned" {
    var obj = ObjectMap.init(std.testing.allocator);
    defer obj.deinit();
    try obj.put("pos", .{ .integer = 100 });
    try obj.put("neg", .{ .integer = -1 });
    try obj.put("str", .{ .string = "hello" });

    try std.testing.expectEqual(@as(u64, 100), getUnsigned(obj, "pos").?);
    try std.testing.expect(getUnsigned(obj, "neg") == null);
    try std.testing.expect(getUnsigned(obj, "str") == null);
    try std.testing.expect(getUnsigned(obj, "missing") == null);
}

test "getObject" {
    var obj = ObjectMap.init(std.testing.allocator);
    defer obj.deinit();

    var inner = ObjectMap.init(std.testing.allocator);
    try inner.put("key", .{ .string = "val" });
    try obj.put("nested", .{ .object = inner });
    try obj.put("num", .{ .integer = 1 });

    const nested = getObject(obj, "nested");
    try std.testing.expect(nested != null);
    try std.testing.expectEqualStrings("val", getString(nested.?, "key").?);

    try std.testing.expect(getObject(obj, "num") == null);
    try std.testing.expect(getObject(obj, "missing") == null);
}

test "getArray" {
    var obj = ObjectMap.init(std.testing.allocator);
    defer obj.deinit();

    var arr = std.json.Array.init(std.testing.allocator);
    try arr.append(.{ .integer = 1 });
    try arr.append(.{ .integer = 2 });
    try obj.put("list", .{ .array = arr });
    try obj.put("num", .{ .integer = 1 });

    const items = getArray(obj, "list");
    try std.testing.expect(items != null);
    try std.testing.expectEqual(@as(usize, 2), items.?.len);
    try std.testing.expectEqual(@as(i64, 1), items.?[0].integer);

    try std.testing.expect(getArray(obj, "num") == null);
    try std.testing.expect(getArray(obj, "missing") == null);
}

test "jsonString and jsonInteger and jsonBool" {
    const s = jsonString("hello");
    try std.testing.expectEqualStrings("hello", s.string);

    const i = jsonInteger(42);
    try std.testing.expectEqual(@as(i64, 42), i.integer);

    const bt = jsonBool(true);
    try std.testing.expect(bt.bool == true);

    const bf = jsonBool(false);
    try std.testing.expect(bf.bool == false);
}
