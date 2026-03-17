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

/// Get a u32 value from a JSON object by key.
/// Returns null if the key is missing, the value is not an integer,
/// the value is negative, or the value exceeds u32 max.
/// This is the safe alternative to @intCast(getInteger(...)) which can
/// wraparound on negative values in ReleaseFast mode.
pub fn getU32(obj: ObjectMap, key: []const u8) ?u32 {
    const val = obj.get(key) orelse return null;
    const i = switch (val) {
        .integer => |n| n,
        else => return null,
    };
    return std.math.cast(u32, i);
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

/// Stringify a JSON value to a std.Io.Writer.
pub fn stringifyToWriter(value: Value, w: *std.Io.Writer) !void {
    try std.json.Stringify.value(value, .{}, w);
}

/// Stringify a JSON value to an allocated string.
pub fn stringifyAlloc(allocator: Allocator, value: Value) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
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

/// Build an ObjectMap from a comptime-known list of key-value pairs.
/// Usage:
///   const obj = try buildObject(alloc, .{
///       .{ "name", jsonString("foo") },
///       .{ "line", jsonInteger(42) },
///       .{ "enabled", jsonBool(true) },
///   });
/// Returns a Value (.object) ready for embedding in JSON structures.
pub fn buildObject(allocator: Allocator, entries: anytype) !Value {
    var map = ObjectMap.init(allocator);
    inline for (entries) |entry| {
        try map.put(entry[0], coerceValue(entry[1]));
    }
    return .{ .object = map };
}

/// Build an ObjectMap from entries, returning the raw ObjectMap (not wrapped in Value).
/// Useful when you need to mutate the map after construction (e.g. add conditional fields).
pub fn buildObjectMap(allocator: Allocator, entries: anytype) !ObjectMap {
    var map = ObjectMap.init(allocator);
    inline for (entries) |entry| {
        try map.put(entry[0], coerceValue(entry[1]));
    }
    return map;
}

/// Coerce a value to Value. Accepts Value directly or anonymous struct literals
/// like .{ .array = arr }, .{ .object = obj }, .{ .bool = b }.
fn coerceValue(v: anytype) Value {
    const T = @TypeOf(v);
    if (T == Value) return v;
    // Anonymous struct with known Value fields — coerce via tagged union init.
    if (@hasField(T, "array")) return .{ .array = v.array };
    if (@hasField(T, "object")) return .{ .object = v.object };
    if (@hasField(T, "bool")) return if (v.bool) .{ .bool = true } else .{ .bool = false };
    if (@hasField(T, "string")) return .{ .string = v.string };
    if (@hasField(T, "integer")) return .{ .integer = v.integer };
    @compileError("buildObject entry value must be a Value or an anonymous struct with a known Value field (.array, .object, .bool, .string, .integer)");
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

test "buildObject" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const val = try buildObject(alloc, .{
        .{ "name", jsonString("foo") },
        .{ "line", jsonInteger(42) },
        .{ "ok", jsonBool(true) },
    });
    const obj = val.object;
    try std.testing.expectEqualStrings("foo", getString(obj, "name").?);
    try std.testing.expectEqual(@as(i64, 42), getInteger(obj, "line").?);
    try std.testing.expect(obj.get("ok").?.bool == true);
}

test "buildObjectMap" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var map = try buildObjectMap(alloc, .{
        .{ "key", jsonString("val") },
    });
    // Can mutate after construction
    try map.put("extra", jsonInteger(99));
    try std.testing.expectEqualStrings("val", getString(map, "key").?);
    try std.testing.expectEqual(@as(i64, 99), getInteger(map, "extra").?);
}

test "getU32: returns value for valid non-negative integer" {
    var obj = ObjectMap.init(std.testing.allocator);
    defer obj.deinit();
    try obj.put("line", .{ .integer = 42 });
    try std.testing.expectEqual(@as(u32, 42), getU32(obj, "line").?);
}

test "getU32: returns null for negative integer (no wraparound)" {
    var obj = ObjectMap.init(std.testing.allocator);
    defer obj.deinit();
    try obj.put("line", .{ .integer = -1 });
    try std.testing.expect(getU32(obj, "line") == null);
}

test "getU32: returns null for large negative integer" {
    var obj = ObjectMap.init(std.testing.allocator);
    defer obj.deinit();
    try obj.put("line", .{ .integer = std.math.minInt(i64) });
    try std.testing.expect(getU32(obj, "line") == null);
}

test "getU32: returns null for value exceeding u32 max" {
    var obj = ObjectMap.init(std.testing.allocator);
    defer obj.deinit();
    try obj.put("line", .{ .integer = @as(i64, std.math.maxInt(u32)) + 1 });
    try std.testing.expect(getU32(obj, "line") == null);
}

test "getU32: returns value for u32 max boundary" {
    var obj = ObjectMap.init(std.testing.allocator);
    defer obj.deinit();
    try obj.put("line", .{ .integer = std.math.maxInt(u32) });
    try std.testing.expectEqual(@as(u32, std.math.maxInt(u32)), getU32(obj, "line").?);
}

test "getU32: returns null for missing key" {
    var obj = ObjectMap.init(std.testing.allocator);
    defer obj.deinit();
    try std.testing.expect(getU32(obj, "missing") == null);
}

test "getU32: returns zero for zero value" {
    var obj = ObjectMap.init(std.testing.allocator);
    defer obj.deinit();
    try obj.put("line", .{ .integer = 0 });
    try std.testing.expectEqual(@as(u32, 0), getU32(obj, "line").?);
}
