const std = @import("std");
const json = @import("../json_utils.zig");

const Allocator = std.mem.Allocator;
const Value = json.Value;
const Writer = std.io.Writer;

const CONTENT_LENGTH_HEADER = "Content-Length: ";
const HEADER_DELIMITER = "\r\n\r\n";
const MAX_BUFFER_SIZE = 1024 * 1024; // 1MB

// ============================================================================
// JSON-RPC Request ID — integer or string per JSON-RPC 2.0 spec
// ============================================================================

pub const RequestId = union(enum) {
    integer: i64,
    string: []const u8,

    /// Try to extract as u32 (for matching our generated request IDs).
    pub fn asU32(self: RequestId) ?u32 {
        return switch (self) {
            .integer => |i| std.math.cast(u32, i),
            .string => null,
        };
    }

    /// Convert from a JSON Value. Returns null for non-id types.
    pub fn fromValue(val: Value) ?RequestId {
        return switch (val) {
            .integer => |i| .{ .integer = i },
            .string => |s| .{ .string = s },
            else => null,
        };
    }

    /// Convert to a JSON Value (for serialization).
    pub fn toValue(self: RequestId) Value {
        return switch (self) {
            .integer => |i| .{ .integer = i },
            .string => |s| .{ .string = s },
        };
    }

    /// std.fmt support — prints integer as number, string as quoted string.
    pub fn format(self: RequestId, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        switch (self) {
            .integer => |i| try writer.print("{d}", .{i}),
            .string => |s| try writer.print("\"{s}\"", .{s}),
        }
    }
};

// ============================================================================
// LSP Message Framing
//
// LSP uses Content-Length headers:
//   Content-Length: 42\r\n\r\n{"jsonrpc":"2.0",...}
// ============================================================================

pub const MessageFramer = struct {
    allocator: Allocator,
    buffer: std.ArrayList(u8),

    pub fn init(allocator: Allocator) MessageFramer {
        return .{
            .allocator = allocator,
            .buffer = .{},
        };
    }

    pub fn deinit(self: *MessageFramer) void {
        self.buffer.deinit(self.allocator);
    }

    /// Frame a message with Content-Length header. Returns owned slice.
    pub fn frameMessage(self: *MessageFramer, allocator: Allocator, content: []const u8) ![]const u8 {
        _ = self;
        var aw: Writer.Allocating = .init(allocator);
        errdefer aw.deinit();
        const w = &aw.writer;

        try w.writeAll(CONTENT_LENGTH_HEADER);
        try w.print("{d}", .{content.len});
        try w.writeAll("\r\n\r\n");
        try w.writeAll(content);
        return aw.toOwnedSlice();
    }

    /// Feed data into the buffer and extract complete messages.
    /// Returns a list of message body strings. Caller must free each.
    pub fn feedData(self: *MessageFramer, allocator: Allocator, data: []const u8) !std.ArrayList([]const u8) {
        if (self.buffer.items.len + data.len > MAX_BUFFER_SIZE) {
            return error.BufferOverflow;
        }

        try self.buffer.appendSlice(self.allocator, data);

        var messages: std.ArrayList([]const u8) = .{};
        errdefer {
            for (messages.items) |msg| allocator.free(msg);
            messages.deinit(allocator);
        }

        while (self.buffer.items.len > 0) {
            const header_end = self.findHeaderEnd() orelse break;
            const content_length = try self.parseContentLength(header_end);
            const message_start = header_end + HEADER_DELIMITER.len;
            const message_end = message_start + content_length;

            if (self.buffer.items.len < message_end) break;

            // Copy message body
            const msg = try allocator.dupe(u8, self.buffer.items[message_start..message_end]);
            try messages.append(allocator, msg);

            // Remove consumed bytes: shift remaining data to front
            const remaining = self.buffer.items.len - message_end;
            if (remaining > 0) {
                std.mem.copyForwards(u8, self.buffer.items[0..remaining], self.buffer.items[message_end..]);
            }
            self.buffer.shrinkRetainingCapacity(remaining);
        }

        return messages;
    }

    fn findHeaderEnd(self: *const MessageFramer) ?usize {
        const buf = self.buffer.items;
        if (buf.len < HEADER_DELIMITER.len) return null;
        for (0..buf.len - HEADER_DELIMITER.len + 1) |i| {
            if (std.mem.eql(u8, buf[i..][0..HEADER_DELIMITER.len], HEADER_DELIMITER)) {
                return i;
            }
        }
        return null;
    }

    fn parseContentLength(self: *const MessageFramer, header_end: usize) !usize {
        const header = self.buffer.items[0..header_end];

        var iter = std.mem.splitSequence(u8, header, "\r\n");
        while (iter.next()) |line| {
            if (std.mem.startsWith(u8, line, CONTENT_LENGTH_HEADER)) {
                const length_str = line[CONTENT_LENGTH_HEADER.len..];
                return std.fmt.parseInt(usize, length_str, 10) catch return error.InvalidContentLength;
            }
        }
        return error.MissingContentLength;
    }
};

// ============================================================================
// Comptime method ↔ params binding
//
// LspRequest("textDocument/hover", TextDocumentPositionParams) generates a
// struct that pairs the method string with its params type at compile time.
// sendRequest/sendNotification use @hasDecl(T, "method") to enforce this.
// ============================================================================

/// Concrete wire-format type for LSP requests and notifications.
/// Produced by `wire()` on typed requests/notifications.
pub const Wire = struct {
    method: []const u8,
    params: Value,
};

pub fn LspRequest(comptime method_name: []const u8, comptime Params: type) type {
    return struct {
        pub const method = method_name;
        pub const ParamsType = Params;
        params: Params,

        /// Serialize typed params to wire format.
        pub fn wire(self: @This(), alloc: Allocator) !Wire {
            return .{
                .method = method,
                .params = if (Params == Value) self.params else try json.structToValue(alloc, self.params),
            };
        }
    };
}

pub fn LspNotification(comptime method_name: []const u8, comptime Params: type) type {
    return struct {
        pub const method = method_name;
        pub const ParamsType = Params;
        params: Params,

        /// Serialize typed params to wire format.
        pub fn wire(self: @This(), alloc: Allocator) !Wire {
            return .{
                .method = method,
                .params = if (Params == Value) self.params else try json.structToValue(alloc, self.params),
            };
        }
    };
}

// ============================================================================
// JSON-RPC Message — unified protocol type with serialize/deserialize
// ============================================================================

pub const Request = struct { id: RequestId, method: []const u8, params: Value };
pub const Response = struct { id: RequestId, result: Value, err: ?Value = null };
pub const Notification = struct { method: []const u8, params: Value };

pub const Message = union(enum) {
    /// Request (method + id) — outgoing or incoming (server request)
    request: Request,
    /// Response (id + result/error)
    response: Response,
    /// Notification (method, no id, no response expected)
    notification: Notification,

    /// Serialize to Content-Length framed JSON-RPC bytes (wire format).
    pub fn serialize(self: Message, allocator: Allocator) ![]const u8 {
        // Step 1: serialize JSON body
        var body_w: Writer.Allocating = .init(allocator);
        errdefer body_w.deinit();
        const bw = &body_w.writer;

        switch (self) {
            .request => |r| {
                try bw.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
                try json.stringifyToWriter(r.id.toValue(), bw);
                try bw.writeAll(",\"method\":");
                try json.stringifyToWriter(json.jsonString(r.method), bw);
                try bw.writeAll(",\"params\":");
                try json.stringifyToWriter(r.params, bw);
                try bw.writeByte('}');
            },
            .response => |r| {
                try bw.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
                try json.stringifyToWriter(r.id.toValue(), bw);
                try bw.writeAll(",\"result\":");
                try json.stringifyToWriter(r.result, bw);
                try bw.writeByte('}');
            },
            .notification => |n| {
                try bw.writeAll("{\"jsonrpc\":\"2.0\",\"method\":");
                try json.stringifyToWriter(json.jsonString(n.method), bw);
                try bw.writeAll(",\"params\":");
                try json.stringifyToWriter(n.params, bw);
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

    /// Classify a parsed JSON-RPC value into a Message.
    pub fn fromValue(allocator: Allocator, value: Value) ?Message {
        const raw = json.parseTyped(RpcRaw, allocator, value) orelse return null;

        if (raw.method) |method| {
            if (raw.id) |id_val| {
                const id = RequestId.fromValue(id_val) orelse return null;
                return .{ .request = .{ .id = id, .method = method, .params = raw.params } };
            } else {
                return .{ .notification = .{ .method = method, .params = raw.params } };
            }
        } else if (raw.id) |id_val| {
            const id = RequestId.fromValue(id_val) orelse return null;
            return .{ .response = .{ .id = id, .result = raw.result orelse .null, .err = raw.@"error" } };
        }
        return null;
    }

    const RpcRaw = struct {
        id: ?Value = null,
        method: ?[]const u8 = null,
        params: Value = .null,
        result: ?Value = null,
        @"error": ?Value = null,
    };
};

// ============================================================================
// Tests
// ============================================================================

test "frame message" {
    const allocator = std.testing.allocator;
    var framer = MessageFramer.init(allocator);
    defer framer.deinit();

    const content = "{\"jsonrpc\":\"2.0\",\"id\":1}";
    const framed = try framer.frameMessage(allocator, content);
    defer allocator.free(framed);

    const expected = "Content-Length: 24\r\n\r\n{\"jsonrpc\":\"2.0\",\"id\":1}";
    try std.testing.expectEqualStrings(expected, framed);
}

test "parse single message" {
    const allocator = std.testing.allocator;
    var framer = MessageFramer.init(allocator);
    defer framer.deinit();

    const content = "{\"jsonrpc\":\"2.0\",\"id\":1}";
    const raw = "Content-Length: 24\r\n\r\n{\"jsonrpc\":\"2.0\",\"id\":1}";

    var messages = try framer.feedData(allocator, raw);
    defer {
        for (messages.items) |msg| allocator.free(msg);
        messages.deinit(allocator);
    }

    try std.testing.expectEqual(@as(usize, 1), messages.items.len);
    try std.testing.expectEqualStrings(content, messages.items[0]);
}

test "parse partial message" {
    const allocator = std.testing.allocator;
    var framer = MessageFramer.init(allocator);
    defer framer.deinit();

    // Feed header only
    var messages1 = try framer.feedData(allocator, "Content-Length: 5\r\n\r\n");
    defer {
        for (messages1.items) |msg| allocator.free(msg);
        messages1.deinit(allocator);
    }
    try std.testing.expectEqual(@as(usize, 0), messages1.items.len);

    // Feed body
    var messages2 = try framer.feedData(allocator, "hello");
    defer {
        for (messages2.items) |msg| allocator.free(msg);
        messages2.deinit(allocator);
    }
    try std.testing.expectEqual(@as(usize, 1), messages2.items.len);
    try std.testing.expectEqualStrings("hello", messages2.items[0]);
}

test "Message serialize request" {
    const allocator = std.testing.allocator;
    const msg = Message{ .request = .{ .id = .{ .integer = 1 }, .method = "initialize", .params = .null } };
    const data = try msg.serialize(allocator);
    defer allocator.free(data);

    const body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":null}";
    const expected = "Content-Length: 60\r\n\r\n" ++ body;
    try std.testing.expectEqualStrings(expected, data);
}

test "Message serialize response" {
    const allocator = std.testing.allocator;
    const msg = Message{ .response = .{ .id = .{ .integer = 42 }, .result = .null } };
    const data = try msg.serialize(allocator);
    defer allocator.free(data);

    const body = "{\"jsonrpc\":\"2.0\",\"id\":42,\"result\":null}";
    const expected = "Content-Length: 39\r\n\r\n" ++ body;
    try std.testing.expectEqualStrings(expected, data);
}

test "Message fromValue — response" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var obj = std.json.ObjectMap.init(alloc);
    try obj.put("id", .{ .integer = 1 });
    try obj.put("result", .null);

    const msg = Message.fromValue(alloc, .{ .object = obj }).?;
    switch (msg) {
        .response => |r| {
            try std.testing.expectEqual(@as(i64, 1), r.id.integer);
            try std.testing.expect(r.result == .null);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "Message fromValue — notification" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var obj = std.json.ObjectMap.init(alloc);
    try obj.put("method", .{ .string = "textDocument/didOpen" });

    const msg = Message.fromValue(alloc, .{ .object = obj }).?;
    switch (msg) {
        .notification => |n| try std.testing.expectEqualStrings("textDocument/didOpen", n.method),
        else => return error.TestUnexpectedResult,
    }
}

test "Message fromValue — request (server→client)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var obj = std.json.ObjectMap.init(alloc);
    try obj.put("id", .{ .integer = 5 });
    try obj.put("method", .{ .string = "workspace/applyEdit" });

    const msg = Message.fromValue(alloc, .{ .object = obj }).?;
    switch (msg) {
        .request => |r| {
            try std.testing.expectEqualStrings("workspace/applyEdit", r.method);
            try std.testing.expectEqual(@as(i64, 5), r.id.integer);
        },
        else => return error.TestUnexpectedResult,
    }
}
