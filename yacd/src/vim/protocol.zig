const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

// ============================================================================
// Vim Channel Protocol — JSON message types and encoding/decoding
//
// Vim channel protocol uses JSON arrays:
//   Request:      [positive_id, {"method": "xxx", "params": {...}}]
//   Response:     [-id, result]                  (negative of request id)
//   Notification: [0, {"action": "xxx", "params": {...}}]  (server push)
// ============================================================================

pub const VimMessage = union(enum) {
    request: Request,
    response: Response,
    notification: Notification,

    pub const Request = struct {
        id: u32,
        method: []const u8,
        params: std.json.Value,
    };

    pub const Response = struct {
        id: u32,
        result: std.json.Value,
    };

    pub const Notification = struct {
        action: []const u8,
        params: std.json.Value,
    };
};

/// Parse a raw JSON line into a VimMessage using the caller's allocator directly.
/// Unlike `parse()`, does NOT create a hidden internal arena — all memory lives
/// in `allocator`. Caller must ensure `json_line` outlives the returned VimMessage
/// (or dupe it into the allocator beforehand).
pub fn parseLeaky(allocator: Allocator, json_line: []const u8) !VimMessage {
    const value = try std.json.parseFromSliceLeaky(std.json.Value, allocator, json_line, .{});
    const arr = switch (value) {
        .array => |a| a.items,
        else => return error.InvalidProtocol,
    };
    return parseArray(arr);
}

/// Parse a JSON array (already decoded) into a VimMessage.
fn parseArray(arr: []const std.json.Value) !VimMessage {
    switch (arr.len) {
        1 => {
            // Notification from Vim: [{"method": ..., "params": ...}]
            const obj = switch (arr[0]) {
                .object => |o| o,
                else => return error.InvalidProtocol,
            };
            const method = switch (obj.get("method") orelse return error.InvalidProtocol) {
                .string => |s| s,
                else => return error.InvalidProtocol,
            };
            const params = obj.get("params") orelse .null;
            return .{ .notification = .{ .action = method, .params = params } };
        },
        2 => {
            // Request or Response based on ID sign
            const id_val: i64 = switch (arr[0]) {
                .integer => |i| i,
                else => return error.InvalidProtocol,
            };

            if (id_val > 0) {
                // Request: [positive_id, {"method": ..., "params": ...}]
                const obj = switch (arr[1]) {
                    .object => |o| o,
                    else => return error.InvalidProtocol,
                };
                const method = switch (obj.get("method") orelse return error.InvalidProtocol) {
                    .string => |s| s,
                    else => return error.InvalidProtocol,
                };
                const params = obj.get("params") orelse .null;
                return .{ .request = .{
                    .id = @intCast(id_val),
                    .method = method,
                    .params = params,
                } };
            } else if (id_val < 0) {
                // Response: [negative_id, result]
                return .{ .response = .{
                    .id = @intCast(-id_val),
                    .result = arr[1],
                } };
            } else {
                // id == 0: server push (shouldn't come from Vim, but handle gracefully)
                const obj = switch (arr[1]) {
                    .object => |o| o,
                    else => return error.InvalidProtocol,
                };
                const action = switch (obj.get("action") orelse return error.InvalidProtocol) {
                    .string => |s| s,
                    else => return error.InvalidProtocol,
                };
                const params = obj.get("params") orelse .null;
                return .{ .notification = .{ .action = action, .params = params } };
            }
        },
        else => return error.InvalidProtocol,
    }
}

/// Encode a response: [-id, result]\n
/// Caller owns the returned slice.
pub fn encodeResponse(allocator: Allocator, id: u32, result: std.json.Value) ![]const u8 {
    var aw: Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    const w = &aw.writer;

    try w.print("[{d},", .{@as(i64, @intCast(id))});
    try std.json.Stringify.value(result, .{ .emit_null_optional_fields = false }, w);
    try w.writeAll("]\n");

    return aw.toOwnedSlice();
}

/// Encode any VimMessage variant to wire format.
/// Caller owns the returned slice.
pub fn encodeMessage(allocator: Allocator, msg: VimMessage) ![]const u8 {
    return switch (msg) {
        .response => |r| encodeResponse(allocator, r.id, r.result),
        .notification => |n| encodeNotification(allocator, n.action, n.params),
        .request => error.UnsupportedOutbound,
    };
}

/// Encode a server push notification: [0, {"action": action, "params": ...}]\n
/// Caller owns the returned slice.
pub fn encodeNotification(allocator: Allocator, action: []const u8, params: std.json.Value) ![]const u8 {
    var aw: Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    const w = &aw.writer;

    try w.writeAll("[0,{\"action\":");
    try std.json.Stringify.value(@as(std.json.Value, .{ .string = action }), .{}, w);
    try w.writeAll(",\"params\":");
    try std.json.Stringify.value(params, .{ .emit_null_optional_fields = false }, w);
    try w.writeAll("}]\n");

    return aw.toOwnedSlice();
}

/// Encode a server push notification directly from a typed struct: [0, {"action": action, "params": ...}]\n
/// Skips the json.Value intermediate — one-pass serialization from typed struct to wire bytes.
/// Caller owns the returned slice.
pub fn encodeNotificationTyped(allocator: Allocator, comptime action: []const u8, params: anytype) ![]const u8 {
    comptime for (action) |c| {
        if (c == '"' or c == '\\' or c < 0x20)
            @compileError("action must be a simple ASCII identifier, got: " ++ action);
    };
    var aw: Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    const w = &aw.writer;

    try w.writeAll("[0,{\"action\":\"");
    try w.writeAll(action);
    try w.writeAll("\",\"params\":");
    try std.json.Stringify.value(params, .{ .emit_null_optional_fields = false }, w);
    try w.writeAll("}]\n");

    return aw.toOwnedSlice();
}

/// Encode a typed value to std.json.Value via JSON round-trip.
pub fn toJsonValue(allocator: Allocator, value: anytype) !std.json.Value {
    const T = @TypeOf(value);
    if (T == std.json.Value) return value;
    if (T == ?std.json.Value) return value orelse .null;
    if (T == void) return .null;

    // Empty struct (.{}) → empty object {} instead of empty array []
    // Zig serializes zero-field structs as [], but JSON-RPC expects {}.
    const info = @typeInfo(T);
    if (info == .@"struct" and info.@"struct".fields.len == 0) {
        return .{ .object = std.json.ObjectMap.init(allocator) };
    }

    var aw: Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    try std.json.Stringify.value(value, .{ .emit_null_optional_fields = false }, &aw.writer);
    const json = try aw.toOwnedSlice();
    defer allocator.free(json);

    return try std.json.parseFromSliceLeaky(std.json.Value, allocator, json, .{
        .allocate = .alloc_always, // json buffer is about to be freed — strings must be independent copies
    });
}

/// Decode a std.json.Value to a typed value via JSON round-trip.
/// Note: returned value may reference memory in the allocator's arena.
/// Caller must ensure the allocator lives long enough (use arena).
pub fn fromJsonValue(comptime T: type, allocator: Allocator, value: std.json.Value) !T {
    if (T == void) return;
    if (T == std.json.Value) return value;

    var aw: Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    try std.json.Stringify.value(value, .{}, &aw.writer);
    const json = try aw.toOwnedSlice();
    defer allocator.free(json); // Safe now — alloc_always makes independent copies

    return try std.json.parseFromSliceLeaky(T, allocator, json, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always, // Never reference input buffer
    });
}

// ============================================================================
// Tests
// ============================================================================

test "parseLeaky: request with params" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const input = try arena.allocator().dupe(u8, "[1,{\"method\":\"hover\",\"params\":{\"file\":\"test.rs\",\"line\":10,\"col\":5}}]");
    const msg = try parseLeaky(arena.allocator(), input);

    switch (msg) {
        .request => |r| {
            try std.testing.expectEqual(@as(u32, 1), r.id);
            try std.testing.expectEqualStrings("hover", r.method);
        },
        else => return error.TestWrongVariant,
    }
}

test "parseLeaky: request — all memory in caller arena" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Dupe input so parsed strings reference arena memory, not the comptime literal
    const input = try arena.allocator().dupe(u8, "[1,{\"method\":\"hover\",\"params\":{\"file\":\"test.rs\"}}]");
    const msg = try parseLeaky(arena.allocator(), input);

    switch (msg) {
        .request => |r| {
            try std.testing.expectEqual(@as(u32, 1), r.id);
            try std.testing.expectEqualStrings("hover", r.method);
        },
        else => return error.TestWrongVariant,
    }
}

test "parseLeaky: notification" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const input = try arena.allocator().dupe(u8, "[{\"method\":\"did_change\",\"params\":{\"file\":\"test.rs\"}}]");
    const msg = try parseLeaky(arena.allocator(), input);

    switch (msg) {
        .notification => |n| {
            try std.testing.expectEqualStrings("did_change", n.action);
        },
        else => return error.TestWrongVariant,
    }
}

test "parseLeaky: response" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const input = try arena.allocator().dupe(u8, "[-42,{\"result\":\"ok\"}]");
    const msg = try parseLeaky(arena.allocator(), input);

    switch (msg) {
        .response => |r| {
            try std.testing.expectEqual(@as(u32, 42), r.id);
        },
        else => return error.TestWrongVariant,
    }
}

test "encodeResponse: negative id" {
    const allocator = std.testing.allocator;
    const encoded = try encodeResponse(allocator, 42, .{ .string = "ok" });
    defer allocator.free(encoded);

    try std.testing.expectEqualStrings("[42,\"ok\"]\n", encoded);
}

test "encodeNotification: action + params" {
    const allocator = std.testing.allocator;
    const encoded = try encodeNotification(allocator, "diagnostics", .null);
    defer allocator.free(encoded);

    try std.testing.expectEqualStrings("[0,{\"action\":\"diagnostics\",\"params\":null}]\n", encoded);
}

test "encodeNotificationTyped: struct params" {
    const allocator = std.testing.allocator;
    const S = struct { file: []const u8, version: u32 };
    const encoded = try encodeNotificationTyped(allocator, "ts_highlights", S{ .file = "test.zig", .version = 1 });
    defer allocator.free(encoded);

    try std.testing.expectEqualStrings(
        "[0,{\"action\":\"ts_highlights\",\"params\":{\"file\":\"test.zig\",\"version\":1}}]\n",
        encoded,
    );
}

test "encodeNotificationTyped: empty slice params" {
    const allocator = std.testing.allocator;
    const S = struct { file: []const u8, hints: []const u8 };
    const encoded = try encodeNotificationTyped(allocator, "inlay_hints", S{ .file = "test.rs", .hints = "" });
    defer allocator.free(encoded);

    try std.testing.expectEqualStrings(
        "[0,{\"action\":\"inlay_hints\",\"params\":{\"file\":\"test.rs\",\"hints\":\"\"}}]\n",
        encoded,
    );
}

test "toJsonValue: struct" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const S = struct { x: u32, y: []const u8 };
    const val = try toJsonValue(arena.allocator(), S{ .x = 42, .y = "hello" });
    _ = val;
}

test "fromJsonValue: struct" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const input = "{\"x\":42,\"y\":\"hello\"}";
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, input, .{});
    const S = struct { x: u32, y: []const u8 };
    const result = try fromJsonValue(S, allocator, parsed.value);

    try std.testing.expectEqual(@as(u32, 42), result.x);
    try std.testing.expectEqualStrings("hello", result.y);
}
