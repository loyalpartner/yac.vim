const std = @import("std");
const json = @import("../json_utils.zig");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;
const Value = json.Value;
const ObjectMap = json.ObjectMap;
const Writer = std.io.Writer;

/// Re-export MessageFramer — DAP uses the same Content-Length framing as LSP.
pub const MessageFramer = @import("../lsp/protocol.zig").MessageFramer;

// ============================================================================
// DAP Message Types
//
// DAP protocol: {seq, type, command/event, arguments/body}
// NOT JSON-RPC — uses seq/request_seq instead of id.
// Spec: https://microsoft.github.io/debug-adapter-protocol/specification
// ============================================================================

pub const DapResponse = struct {
    request_seq: u32,
    success: bool,
    command: []const u8,
    message: ?[]const u8,
    body: Value,
};

pub const DapEvent = struct {
    event: []const u8,
    body: Value,
};

pub const DapMessage = union(enum) {
    response: DapResponse,
    event: DapEvent,
};

// ============================================================================
// Build functions
// ============================================================================

/// Build a DAP request JSON string (without Content-Length framing).
pub fn buildDapRequest(allocator: Allocator, seq: u32, command: []const u8, arguments: Value) ![]const u8 {
    var aw: Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    const w = &aw.writer;

    try w.print("{{\"seq\":{d},\"type\":\"request\",\"command\":", .{seq});
    try json.stringifyToWriter(json.jsonString(command), w);
    if (arguments != .null) {
        try w.writeAll(",\"arguments\":");
        try json.stringifyToWriter(arguments, w);
    }
    try w.writeByte('}');

    return aw.toOwnedSlice();
}

/// Build a DAP response JSON string (for reverse requests like runInTerminal).
pub fn buildDapResponse(allocator: Allocator, seq: u32, request_seq: u32, command: []const u8, success: bool, body: Value) ![]const u8 {
    var aw: Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    const w = &aw.writer;

    try w.print("{{\"seq\":{d},\"type\":\"response\",\"request_seq\":{d},\"success\":{},\"command\":", .{ seq, request_seq, success });
    try json.stringifyToWriter(json.jsonString(command), w);
    if (body != .null) {
        try w.writeAll(",\"body\":");
        try json.stringifyToWriter(body, w);
    }
    try w.writeByte('}');

    return aw.toOwnedSlice();
}

// ============================================================================
// Parse functions
// ============================================================================

/// Parse a JSON object into a DapMessage (response or event).
/// Returns null for unrecognized message types (e.g. reverse requests).
pub fn parseDapMessage(alloc: Allocator, obj: ObjectMap) ?DapMessage {
    const raw = types.parse(types.DapMessageRaw, alloc, .{ .object = obj }) orelse return null;
    const msg_type = raw.type orelse return null;

    if (std.mem.eql(u8, msg_type, "response")) {
        const req_seq = raw.request_seq orelse return null;
        if (req_seq < 0) return null;
        const success = raw.success orelse return null;
        return .{ .response = .{
            .request_seq = @intCast(req_seq),
            .success = success,
            .command = raw.command orelse "",
            .message = raw.message,
            .body = raw.body,
        } };
    }

    if (std.mem.eql(u8, msg_type, "event")) {
        return .{ .event = .{
            .event = raw.event orelse return null,
            .body = raw.body,
        } };
    }

    return null;
}

// ============================================================================
// Tests
// ============================================================================

test "buildDapRequest: no arguments" {
    const allocator = std.testing.allocator;
    const req = try buildDapRequest(allocator, 1, "initialize", .null);
    defer allocator.free(req);
    try std.testing.expectEqualStrings(
        "{\"seq\":1,\"type\":\"request\",\"command\":\"initialize\"}",
        req,
    );
}

test "buildDapRequest: with arguments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const args = try json.buildObject(alloc, .{
        .{ "threadId", json.jsonInteger(3) },
    });
    const req = try buildDapRequest(alloc, 5, "continue", args);

    // Round-trip: parse back and verify fields
    const parsed = try std.json.parseFromSlice(Value, alloc, req, .{});
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.NotObject,
    };
    try std.testing.expectEqual(@as(i64, 5), json.getInteger(obj, "seq").?);
    try std.testing.expectEqualStrings("request", json.getString(obj, "type").?);
    try std.testing.expectEqualStrings("continue", json.getString(obj, "command").?);

    const arg_obj = switch (obj.get("arguments").?) {
        .object => |o| o,
        else => return error.NotObject,
    };
    try std.testing.expectEqual(@as(i64, 3), json.getInteger(arg_obj, "threadId").?);
}

test "buildDapResponse: success" {
    const allocator = std.testing.allocator;
    const resp = try buildDapResponse(allocator, 2, 1, "initialize", true, .null);
    defer allocator.free(resp);
    try std.testing.expectEqualStrings(
        "{\"seq\":2,\"type\":\"response\",\"request_seq\":1,\"success\":true,\"command\":\"initialize\"}",
        resp,
    );
}

test "parseDapMessage: response" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const val = try json.buildObject(alloc, .{
        .{ "seq", json.jsonInteger(2) },
        .{ "type", json.jsonString("response") },
        .{ "request_seq", json.jsonInteger(1) },
        .{ "success", .{ .bool = true } },
        .{ "command", json.jsonString("initialize") },
    });
    const obj = switch (val) {
        .object => |o| o,
        else => return error.NotObject,
    };

    const msg = parseDapMessage(alloc, obj) orelse return error.ParseFailed;
    switch (msg) {
        .response => |r| {
            try std.testing.expectEqual(@as(u32, 1), r.request_seq);
            try std.testing.expect(r.success);
            try std.testing.expectEqualStrings("initialize", r.command);
        },
        else => return error.WrongType,
    }
}

test "parseDapMessage: event" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const val = try json.buildObject(alloc, .{
        .{ "seq", json.jsonInteger(5) },
        .{ "type", json.jsonString("event") },
        .{ "event", json.jsonString("stopped") },
        .{ "body", try json.buildObject(alloc, .{
            .{ "reason", json.jsonString("breakpoint") },
            .{ "threadId", json.jsonInteger(1) },
        }) },
    });
    const obj = switch (val) {
        .object => |o| o,
        else => return error.NotObject,
    };

    const msg = parseDapMessage(alloc, obj) orelse return error.ParseFailed;
    switch (msg) {
        .event => |e| {
            try std.testing.expectEqualStrings("stopped", e.event);
            const body = switch (e.body) {
                .object => |o| o,
                else => return error.NotObject,
            };
            try std.testing.expectEqualStrings("breakpoint", json.getString(body, "reason").?);
            try std.testing.expectEqual(@as(i64, 1), json.getInteger(body, "threadId").?);
        },
        else => return error.WrongType,
    }
}

test "parseDapMessage: failed response" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const val = try json.buildObject(alloc, .{
        .{ "seq", json.jsonInteger(3) },
        .{ "type", json.jsonString("response") },
        .{ "request_seq", json.jsonInteger(2) },
        .{ "success", .{ .bool = false } },
        .{ "command", json.jsonString("launch") },
        .{ "message", json.jsonString("Could not find debuggee") },
    });
    const obj = switch (val) {
        .object => |o| o,
        else => return error.NotObject,
    };

    const msg = parseDapMessage(alloc, obj) orelse return error.ParseFailed;
    switch (msg) {
        .response => |r| {
            try std.testing.expect(!r.success);
            try std.testing.expectEqualStrings("Could not find debuggee", r.message.?);
        },
        else => return error.WrongType,
    }
}

test "parseDapMessage: unknown type returns null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const val = try json.buildObject(alloc, .{
        .{ "type", json.jsonString("garbage") },
    });
    const obj = switch (val) {
        .object => |o| o,
        else => return error.NotObject,
    };

    try std.testing.expect(parseDapMessage(alloc, obj) == null);
}

test "parseDapMessage: missing type returns null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const val = try json.buildObject(alloc, .{
        .{ "seq", json.jsonInteger(1) },
    });
    const obj = switch (val) {
        .object => |o| o,
        else => return error.NotObject,
    };

    try std.testing.expect(parseDapMessage(alloc, obj) == null);
}
