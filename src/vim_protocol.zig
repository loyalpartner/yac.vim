const std = @import("std");
const json = @import("json_utils.zig");

const Allocator = std.mem.Allocator;
const Value = json.Value;
const ObjectMap = json.ObjectMap;
const ArrayList = std.ArrayList;

// ============================================================================
// JSON-RPC Messages (Vim <-> lsp-bridge)
//
// Vim channel protocol uses JSON arrays:
//   Request:      [positive_id, {"method": "xxx", "params": {...}}]
//   Response:     [negative_id, result]
//   Notification: [{"method": "xxx", "params": {...}}]
// ============================================================================

pub const JsonRpcMessage = union(enum) {
    request: struct {
        id: u64,
        method: []const u8,
        params: Value,
    },
    response: struct {
        id: i64,
        result: Value,
    },
    notification: struct {
        method: []const u8,
        params: Value,
    },
};

/// Parse a Vim channel JSON array into a JsonRpcMessage.
pub fn parseJsonRpc(arr: []const Value) !JsonRpcMessage {
    switch (arr.len) {
        1 => {
            // Notification: [{"method": "xxx", "params": ...}]
            const obj = switch (arr[0]) {
                .object => |o| o,
                else => return error.InvalidProtocol,
            };
            const method = json.getString(obj, "method") orelse return error.InvalidProtocol;
            const params = obj.get("params") orelse .null;
            return .{ .notification = .{ .method = method, .params = params } };
        },
        2 => {
            // Request or Response based on sign of ID
            const id_val = switch (arr[0]) {
                .integer => |i| i,
                else => return error.InvalidProtocol,
            };

            if (id_val > 0) {
                // Request: [positive_id, {"method": "xxx", "params": ...}]
                const obj = switch (arr[1]) {
                    .object => |o| o,
                    else => return error.InvalidProtocol,
                };
                const method = json.getString(obj, "method") orelse return error.InvalidProtocol;
                const params = obj.get("params") orelse .null;
                return .{ .request = .{
                    .id = @intCast(id_val),
                    .method = method,
                    .params = params,
                } };
            } else if (id_val < 0) {
                // Response: [negative_id, result]
                return .{ .response = .{
                    .id = id_val,
                    .result = arr[1],
                } };
            } else {
                return error.InvalidProtocol;
            }
        },
        else => return error.InvalidProtocol,
    }
}

// ============================================================================
// Channel Commands (lsp-bridge -> Vim)
//
// These are outgoing commands we send to Vim:
//   ["call", func, args, id]  -- call with response
//   ["call", func, args]      -- call without response (fire-and-forget)
//   ["expr", expr, id]        -- expression with response
//   ["expr", expr]            -- expression without response
//   ["ex", command]           -- execute ex command
//   ["normal", keys]          -- execute normal mode keys
//   ["redraw", ""|"force"]    -- redraw screen
// ============================================================================

pub const ChannelCommand = union(enum) {
    call: struct { func: []const u8, args: Value, id: i64 },
    call_async: struct { func: []const u8, args: Value },
    expr: struct { expr: []const u8, id: i64 },
    expr_async: struct { expr: []const u8 },
    ex: struct { command: []const u8 },
    normal: struct { keys: []const u8 },
    redraw: struct { force: bool },
};

/// Encode a channel command to a JSON line (caller owns the returned memory).
pub fn encodeChannelCommand(allocator: Allocator, cmd: ChannelCommand) ![]const u8 {
    var buf = ArrayList(u8).init(allocator);
    const writer = buf.writer();

    switch (cmd) {
        .call => |c| {
            try writer.writeAll("[\"call\",");
            try std.json.stringify(json.jsonString(c.func), .{}, writer);
            try writer.writeByte(',');
            try std.json.stringify(c.args, .{}, writer);
            try writer.writeByte(',');
            try std.fmt.formatInt(c.id, 10, .lower, .{}, writer);
            try writer.writeByte(']');
        },
        .call_async => |c| {
            try writer.writeAll("[\"call\",");
            try std.json.stringify(json.jsonString(c.func), .{}, writer);
            try writer.writeByte(',');
            try std.json.stringify(c.args, .{}, writer);
            try writer.writeByte(']');
        },
        .expr => |e| {
            try writer.writeAll("[\"expr\",");
            try std.json.stringify(json.jsonString(e.expr), .{}, writer);
            try writer.writeByte(',');
            try std.fmt.formatInt(e.id, 10, .lower, .{}, writer);
            try writer.writeByte(']');
        },
        .expr_async => |e| {
            try writer.writeAll("[\"expr\",");
            try std.json.stringify(json.jsonString(e.expr), .{}, writer);
            try writer.writeByte(']');
        },
        .ex => |e| {
            try writer.writeAll("[\"ex\",");
            try std.json.stringify(json.jsonString(e.command), .{}, writer);
            try writer.writeByte(']');
        },
        .normal => |n| {
            try writer.writeAll("[\"normal\",");
            try std.json.stringify(json.jsonString(n.keys), .{}, writer);
            try writer.writeByte(']');
        },
        .redraw => |r| {
            if (r.force) {
                try writer.writeAll("[\"redraw\",\"force\"]");
            } else {
                try writer.writeAll("[\"redraw\",\"\"]");
            }
        },
    }

    return buf.toOwnedSlice();
}

/// Encode a JSON-RPC response as a JSON line.
pub fn encodeJsonRpcResponse(allocator: Allocator, id: i64, result: Value) ![]const u8 {
    var buf = ArrayList(u8).init(allocator);
    const writer = buf.writer();

    try writer.writeByte('[');
    try std.fmt.formatInt(id, 10, .lower, .{}, writer);
    try writer.writeByte(',');
    try std.json.stringify(result, .{}, writer);
    try writer.writeByte(']');

    return buf.toOwnedSlice();
}

/// Encode a JSON-RPC request as a JSON line.
pub fn encodeJsonRpcRequest(allocator: Allocator, id: u64, method: []const u8, params: Value) ![]const u8 {
    var buf = ArrayList(u8).init(allocator);
    const writer = buf.writer();

    try writer.writeByte('[');
    try std.fmt.formatInt(id, 10, .lower, .{}, writer);
    try writer.writeAll(",{\"method\":");
    try std.json.stringify(json.jsonString(method), .{}, writer);
    try writer.writeAll(",\"params\":");
    try std.json.stringify(params, .{}, writer);
    try writer.writeAll("}]");

    return buf.toOwnedSlice();
}

/// Encode a JSON-RPC notification as a JSON line.
pub fn encodeJsonRpcNotification(allocator: Allocator, method: []const u8, params: Value) ![]const u8 {
    var buf = ArrayList(u8).init(allocator);
    const writer = buf.writer();

    try writer.writeAll("[{\"method\":");
    try std.json.stringify(json.jsonString(method), .{}, writer);
    try writer.writeAll(",\"params\":");
    try std.json.stringify(params, .{}, writer);
    try writer.writeAll("}]");

    return buf.toOwnedSlice();
}

// ============================================================================
// Tests
// ============================================================================

test "parse JSON-RPC request" {
    const allocator = std.testing.allocator;
    const input = "[1,{\"method\":\"goto_definition\",\"params\":{\"file\":\"test.rs\"}}]";
    const parsed = try json.parse(allocator, input);
    defer parsed.deinit();

    const arr = switch (parsed.value) {
        .array => |a| a.items,
        else => unreachable,
    };

    const msg = try parseJsonRpc(arr);
    switch (msg) {
        .request => |r| {
            try std.testing.expectEqual(@as(u64, 1), r.id);
            try std.testing.expectEqualStrings("goto_definition", r.method);
        },
        else => unreachable,
    }
}

test "parse JSON-RPC response" {
    const allocator = std.testing.allocator;
    const input = "[-42,{\"result\":\"success\"}]";
    const parsed = try json.parse(allocator, input);
    defer parsed.deinit();

    const arr = switch (parsed.value) {
        .array => |a| a.items,
        else => unreachable,
    };

    const msg = try parseJsonRpc(arr);
    switch (msg) {
        .response => |r| {
            try std.testing.expectEqual(@as(i64, -42), r.id);
        },
        else => unreachable,
    }
}

test "parse JSON-RPC notification" {
    const allocator = std.testing.allocator;
    const input = "[{\"method\":\"did_change\",\"params\":{\"file\":\"test.rs\"}}]";
    const parsed = try json.parse(allocator, input);
    defer parsed.deinit();

    const arr = switch (parsed.value) {
        .array => |a| a.items,
        else => unreachable,
    };

    const msg = try parseJsonRpc(arr);
    switch (msg) {
        .notification => |n| {
            try std.testing.expectEqualStrings("did_change", n.method);
        },
        else => unreachable,
    }
}

test "encode channel command - call async" {
    const allocator = std.testing.allocator;

    var args_array = std.json.Array.init(allocator);
    defer args_array.deinit();
    try args_array.append(.{ .string = "arg1" });

    const cmd = ChannelCommand{ .call_async = .{
        .func = "test_func",
        .args = .{ .array = args_array },
    } };

    const encoded = try encodeChannelCommand(allocator, cmd);
    defer allocator.free(encoded);

    try std.testing.expectEqualStrings("[\"call\",\"test_func\",[\"arg1\"]]", encoded);
}

test "encode channel command - ex" {
    const allocator = std.testing.allocator;
    const cmd = ChannelCommand{ .ex = .{ .command = "edit test.rs" } };
    const encoded = try encodeChannelCommand(allocator, cmd);
    defer allocator.free(encoded);
    try std.testing.expectEqualStrings("[\"ex\",\"edit test.rs\"]", encoded);
}

test "encode channel command - redraw force" {
    const allocator = std.testing.allocator;
    const cmd = ChannelCommand{ .redraw = .{ .force = true } };
    const encoded = try encodeChannelCommand(allocator, cmd);
    defer allocator.free(encoded);
    try std.testing.expectEqualStrings("[\"redraw\",\"force\"]", encoded);
}

test "encode JSON-RPC response" {
    const allocator = std.testing.allocator;
    const encoded = try encodeJsonRpcResponse(allocator, -42, .{ .string = "ok" });
    defer allocator.free(encoded);
    try std.testing.expectEqualStrings("[-42,\"ok\"]", encoded);
}
