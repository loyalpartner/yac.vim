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
// Comptime command ↔ args binding (mirrors LSP's LspRequest pattern)
// ============================================================================

pub fn DapRequest(comptime command_name: []const u8, comptime Args: type) type {
    return struct {
        pub const command = command_name;
        pub const ArgsType = Args;
        arguments: Args,
    };
}

// ============================================================================
// DAP Message — unified protocol type with serialize/fromValue
//
// DAP protocol: {seq, type, command/event, arguments/body}
// NOT JSON-RPC — uses seq/request_seq instead of id.
// Spec: https://microsoft.github.io/debug-adapter-protocol/specification
// ============================================================================

pub const Request = struct { seq: u32, command: []const u8, arguments: Value };
pub const Response = struct { request_seq: u32, success: bool, command: []const u8, message: ?[]const u8, body: Value };
pub const Event = struct { event: []const u8, body: Value };

pub const Message = union(enum) {
    request: Request,
    response: Response,
    event: Event,

    /// Serialize to Content-Length framed DAP bytes (wire format).
    pub fn serialize(self: Message, allocator: Allocator) ![]const u8 {
        // Step 1: serialize JSON body
        var body_w: Writer.Allocating = .init(allocator);
        errdefer body_w.deinit();
        const bw = &body_w.writer;

        switch (self) {
            .request => |r| {
                try bw.print("{{\"seq\":{d},\"type\":\"request\",\"command\":", .{r.seq});
                try json.stringifyToWriter(json.jsonString(r.command), bw);
                if (r.arguments != .null) {
                    try bw.writeAll(",\"arguments\":");
                    try json.stringifyToWriter(r.arguments, bw);
                }
                try bw.writeByte('}');
            },
            .response => |r| {
                try bw.print("{{\"seq\":0,\"type\":\"response\",\"request_seq\":{d},\"success\":{},\"command\":", .{ r.request_seq, r.success });
                try json.stringifyToWriter(json.jsonString(r.command), bw);
                if (r.body != .null) {
                    try bw.writeAll(",\"body\":");
                    try json.stringifyToWriter(r.body, bw);
                }
                try bw.writeByte('}');
            },
            .event => |e| {
                try bw.writeAll("{\"seq\":0,\"type\":\"event\",\"event\":");
                try json.stringifyToWriter(json.jsonString(e.event), bw);
                if (e.body != .null) {
                    try bw.writeAll(",\"body\":");
                    try json.stringifyToWriter(e.body, bw);
                }
                try bw.writeByte('}');
            },
        }

        const body = try body_w.toOwnedSlice();
        defer allocator.free(body);

        // Step 2: frame with Content-Length header
        var aw: Writer.Allocating = .init(allocator);
        errdefer aw.deinit();
        const w = &aw.writer;

        try w.writeAll(CONTENT_LENGTH_HEADER);
        try w.print("{d}", .{body.len});
        try w.writeAll(HEADER_DELIMITER);
        try w.writeAll(body);

        return aw.toOwnedSlice();
    }

    /// Classify a parsed JSON object into a Message.
    pub fn fromValue(alloc: Allocator, obj: ObjectMap) ?Message {
        const raw = types.parse(types.DapMessageRaw, alloc, .{ .object = obj }) orelse return null;
        const msg_type = raw.type orelse return null;

        if (std.mem.eql(u8, msg_type, "response")) {
            const req_seq = raw.request_seq orelse return null;
            if (req_seq < 0) return null;
            return .{ .response = .{
                .request_seq = @intCast(req_seq),
                .success = raw.success orelse return null,
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
};

const CONTENT_LENGTH_HEADER = "Content-Length: ";
const HEADER_DELIMITER = "\r\n\r\n";

// ============================================================================
// Tests
// ============================================================================

test "Message serialize request: no arguments" {
    const allocator = std.testing.allocator;
    const data = try (Message{ .request = .{ .seq = 1, .command = "initialize", .arguments = .null } }).serialize(allocator);
    defer allocator.free(data);
    const body = "{\"seq\":1,\"type\":\"request\",\"command\":\"initialize\"}";
    const expected = std.fmt.comptimePrint("Content-Length: {d}\r\n\r\n{s}", .{ body.len, body });
    try std.testing.expectEqualStrings(expected, data);
}

test "Message serialize request: with arguments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const args = try json.buildObject(alloc, .{
        .{ "threadId", json.jsonInteger(3) },
    });
    const data = try (Message{ .request = .{ .seq = 5, .command = "continue", .arguments = args } }).serialize(alloc);

    // Find body after header
    const header_end = std.mem.indexOf(u8, data, "\r\n\r\n").? + 4;
    const body_str = data[header_end..];
    const parsed = try std.json.parseFromSlice(Value, alloc, body_str, .{});
    const obj = parsed.value.object;
    try std.testing.expectEqual(@as(i64, 5), json.getInteger(obj, "seq").?);
    try std.testing.expectEqualStrings("continue", json.getString(obj, "command").?);
}

test "Message serialize response" {
    const allocator = std.testing.allocator;
    const data = try (Message{ .response = .{ .request_seq = 1, .success = true, .command = "initialize", .message = null, .body = .null } }).serialize(allocator);
    defer allocator.free(data);
    const body = "{\"seq\":0,\"type\":\"response\",\"request_seq\":1,\"success\":true,\"command\":\"initialize\"}";
    const expected = std.fmt.comptimePrint("Content-Length: {d}\r\n\r\n{s}", .{ body.len, body });
    try std.testing.expectEqualStrings(expected, data);
}

test "Message fromValue — response" {
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
    const obj = switch (val) { .object => |o| o, else => return error.NotObject };

    const msg = Message.fromValue(alloc, obj) orelse return error.ParseFailed;
    switch (msg) {
        .response => |r| {
            try std.testing.expectEqual(@as(u32, 1), r.request_seq);
            try std.testing.expect(r.success);
            try std.testing.expectEqualStrings("initialize", r.command);
        },
        else => return error.WrongType,
    }
}

test "Message fromValue — event" {
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
    const obj = switch (val) { .object => |o| o, else => return error.NotObject };

    const msg = Message.fromValue(alloc, obj) orelse return error.ParseFailed;
    switch (msg) {
        .event => |e| {
            try std.testing.expectEqualStrings("stopped", e.event);
            const body = switch (e.body) { .object => |o| o, else => return error.NotObject };
            try std.testing.expectEqualStrings("breakpoint", json.getString(body, "reason").?);
        },
        else => return error.WrongType,
    }
}

test "Message fromValue — unknown type returns null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const val = try json.buildObject(alloc, .{ .{ "type", json.jsonString("garbage") } });
    const obj = switch (val) { .object => |o| o, else => return error.NotObject };
    try std.testing.expect(Message.fromValue(alloc, obj) == null);
}

test "Message fromValue — missing type returns null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const val = try json.buildObject(alloc, .{ .{ "seq", json.jsonInteger(1) } });
    const obj = switch (val) { .object => |o| o, else => return error.NotObject };
    try std.testing.expect(Message.fromValue(alloc, obj) == null);
}
