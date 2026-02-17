const std = @import("std");
const json = @import("json_utils.zig");

const Allocator = std.mem.Allocator;
const Value = json.Value;
const ArrayList = std.ArrayList;

const CONTENT_LENGTH_HEADER = "Content-Length: ";
const HEADER_DELIMITER = "\r\n\r\n";
const MAX_BUFFER_SIZE = 1024 * 1024; // 1MB

// ============================================================================
// LSP Message Framing
//
// LSP uses Content-Length headers:
//   Content-Length: 42\r\n\r\n{"jsonrpc":"2.0",...}
// ============================================================================

pub const MessageFramer = struct {
    buffer: ArrayList(u8),

    pub fn init(allocator: Allocator) MessageFramer {
        return .{
            .buffer = ArrayList(u8).init(allocator),
        };
    }

    pub fn deinit(self: *MessageFramer) void {
        self.buffer.deinit();
    }

    /// Frame a message with Content-Length header. Returns owned slice.
    pub fn frameMessage(self: *MessageFramer, allocator: Allocator, content: []const u8) ![]const u8 {
        _ = self;
        var buf = ArrayList(u8).init(allocator);
        const writer = buf.writer();
        try writer.writeAll(CONTENT_LENGTH_HEADER);
        try std.fmt.formatInt(content.len, 10, .lower, .{}, writer);
        try writer.writeAll("\r\n\r\n");
        try writer.writeAll(content);
        return buf.toOwnedSlice();
    }

    /// Feed data into the buffer and extract complete messages.
    /// Returns a list of message body strings. Caller must free each.
    pub fn feedData(self: *MessageFramer, allocator: Allocator, data: []const u8) !ArrayList([]const u8) {
        if (self.buffer.items.len + data.len > MAX_BUFFER_SIZE) {
            return error.BufferOverflow;
        }

        try self.buffer.appendSlice(data);

        var messages = ArrayList([]const u8).init(allocator);
        errdefer {
            for (messages.items) |msg| allocator.free(msg);
            messages.deinit();
        }

        while (self.buffer.items.len > 0) {
            const header_end = self.findHeaderEnd() orelse break;
            const content_length = try self.parseContentLength(header_end);
            const message_start = header_end + HEADER_DELIMITER.len;
            const message_end = message_start + content_length;

            if (self.buffer.items.len < message_end) break;

            // Copy message body
            const msg = try allocator.dupe(u8, self.buffer.items[message_start..message_end]);
            try messages.append(msg);

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

/// Build a JSON-RPC request for LSP.
pub fn buildLspRequest(allocator: Allocator, id: u32, method: []const u8, params: Value) ![]const u8 {
    var buf = ArrayList(u8).init(allocator);
    const writer = buf.writer();

    try writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try std.fmt.formatInt(id, 10, .lower, .{}, writer);
    try writer.writeAll(",\"method\":");
    try std.json.stringify(json.jsonString(method), .{}, writer);
    try writer.writeAll(",\"params\":");
    try std.json.stringify(params, .{}, writer);
    try writer.writeByte('}');

    return buf.toOwnedSlice();
}

/// Build a JSON-RPC notification for LSP.
pub fn buildLspNotification(allocator: Allocator, method: []const u8, params: Value) ![]const u8 {
    var buf = ArrayList(u8).init(allocator);
    const writer = buf.writer();

    try writer.writeAll("{\"jsonrpc\":\"2.0\",\"method\":");
    try std.json.stringify(json.jsonString(method), .{}, writer);
    try writer.writeAll(",\"params\":");
    try std.json.stringify(params, .{}, writer);
    try writer.writeByte('}');

    return buf.toOwnedSlice();
}

/// Build a JSON-RPC response for LSP (responding to server requests).
pub fn buildLspResponse(allocator: Allocator, id: i64, result: Value) ![]const u8 {
    var buf = ArrayList(u8).init(allocator);
    const writer = buf.writer();

    try writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try std.fmt.formatInt(id, 10, .lower, .{}, writer);
    try writer.writeAll(",\"result\":");
    try std.json.stringify(result, .{}, writer);
    try writer.writeByte('}');

    return buf.toOwnedSlice();
}

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
        messages.deinit();
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
        messages1.deinit();
    }
    try std.testing.expectEqual(@as(usize, 0), messages1.items.len);

    // Feed body
    var messages2 = try framer.feedData(allocator, "hello");
    defer {
        for (messages2.items) |msg| allocator.free(msg);
        messages2.deinit();
    }
    try std.testing.expectEqual(@as(usize, 1), messages2.items.len);
    try std.testing.expectEqualStrings("hello", messages2.items[0]);
}

test "build LSP request" {
    const allocator = std.testing.allocator;
    const request = try buildLspRequest(allocator, 1, "initialize", .null);
    defer allocator.free(request);
    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":null}",
        request,
    );
}

test "build LSP response" {
    const allocator = std.testing.allocator;
    const response = try buildLspResponse(allocator, 42, .null);
    defer allocator.free(response);
    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":42,\"result\":null}",
        response,
    );
}
