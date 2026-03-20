const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

/// LSP Content-Length message framer.
///
/// Incrementally accumulates raw bytes via `feed()` and extracts
/// complete JSON bodies. Also provides `frame()` to wrap a JSON
/// body with the Content-Length header for sending.
pub const Framer = struct {
    buf: std.ArrayList(u8),

    pub fn init() Framer {
        return .{ .buf = .empty };
    }

    pub fn deinit(self: *Framer, allocator: Allocator) void {
        self.buf.deinit(allocator);
    }

    /// Wrap a JSON body with Content-Length header.
    /// Caller owns the returned slice.
    pub fn frame(allocator: Allocator, body: []const u8) ![]const u8 {
        var aw: Writer.Allocating = .init(allocator);
        errdefer aw.deinit();
        const w = &aw.writer;
        try w.print("Content-Length: {d}\r\n\r\n", .{body.len});
        try w.writeAll(body);
        return aw.toOwnedSlice();
    }

    /// Feed raw bytes from the transport. Returns a list of complete
    /// JSON bodies extracted so far. Caller owns each slice.
    pub fn feed(self: *Framer, allocator: Allocator, data: []const u8) !std.ArrayList([]const u8) {
        try self.buf.appendSlice(allocator, data);

        var messages: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (messages.items) |m| allocator.free(m);
            messages.deinit(allocator);
        }

        while (true) {
            const header_end = std.mem.indexOf(u8, self.buf.items, "\r\n\r\n") orelse break;
            const content_length = parseContentLength(self.buf.items[0..header_end]) orelse break;
            const body_start = header_end + 4;
            const msg_end = body_start + content_length;
            if (self.buf.items.len < msg_end) break;

            const body = try allocator.dupe(u8, self.buf.items[body_start..msg_end]);
            try messages.append(allocator, body);

            // Shift remaining bytes to front
            const remaining = self.buf.items.len - msg_end;
            if (remaining > 0) {
                std.mem.copyForwards(u8, self.buf.items[0..remaining], self.buf.items[msg_end..]);
            }
            self.buf.items.len = remaining;
        }

        return messages;
    }

    fn parseContentLength(header: []const u8) ?usize {
        const prefix = "Content-Length: ";
        var offset: usize = 0;
        while (offset + prefix.len <= header.len) {
            if (std.mem.startsWith(u8, header[offset..], prefix)) {
                const value_start = offset + prefix.len;
                var end = value_start;
                while (end < header.len and header[end] >= '0' and header[end] <= '9') : (end += 1) {}
                if (end > value_start) {
                    return std.fmt.parseInt(usize, header[value_start..end], 10) catch null;
                }
                return null;
            }
            // Skip to next line
            if (std.mem.indexOf(u8, header[offset..], "\r\n")) |nl| {
                offset += nl + 2;
            } else break;
        }
        return null;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "Framer: frame wraps body with Content-Length" {
    const allocator = std.testing.allocator;
    const body = "{\"jsonrpc\":\"2.0\"}";
    const framed = try Framer.frame(allocator, body);
    defer allocator.free(framed);

    const expected = "Content-Length: 17\r\n\r\n{\"jsonrpc\":\"2.0\"}";
    try std.testing.expectEqualStrings(expected, framed);
}

test "Framer: feed single complete message" {
    const allocator = std.testing.allocator;
    var f = Framer.init();
    defer f.deinit(allocator);

    const raw = "Content-Length: 5\r\n\r\nhello";
    var msgs = try f.feed(allocator, raw);
    defer {
        for (msgs.items) |m| allocator.free(m);
        msgs.deinit(allocator);
    }

    try std.testing.expectEqual(@as(usize, 1), msgs.items.len);
    try std.testing.expectEqualStrings("hello", msgs.items[0]);
}

test "Framer: feed incomplete message then complete" {
    const allocator = std.testing.allocator;
    var f = Framer.init();
    defer f.deinit(allocator);

    // Feed partial header
    var msgs1 = try f.feed(allocator, "Content-Length: 5\r\n");
    defer msgs1.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), msgs1.items.len);

    // Feed rest of header + partial body
    var msgs2 = try f.feed(allocator, "\r\nhel");
    defer msgs2.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), msgs2.items.len);

    // Feed remaining body
    var msgs3 = try f.feed(allocator, "lo");
    defer {
        for (msgs3.items) |m| allocator.free(m);
        msgs3.deinit(allocator);
    }
    try std.testing.expectEqual(@as(usize, 1), msgs3.items.len);
    try std.testing.expectEqualStrings("hello", msgs3.items[0]);
}

test "Framer: feed multiple messages at once" {
    const allocator = std.testing.allocator;
    var f = Framer.init();
    defer f.deinit(allocator);

    const raw = "Content-Length: 1\r\n\r\naContent-Length: 2\r\n\r\nbc";
    var msgs = try f.feed(allocator, raw);
    defer {
        for (msgs.items) |m| allocator.free(m);
        msgs.deinit(allocator);
    }

    try std.testing.expectEqual(@as(usize, 2), msgs.items.len);
    try std.testing.expectEqualStrings("a", msgs.items[0]);
    try std.testing.expectEqualStrings("bc", msgs.items[1]);
}

test "Framer: ignores extra headers" {
    const allocator = std.testing.allocator;
    var f = Framer.init();
    defer f.deinit(allocator);

    const raw = "Content-Type: utf-8\r\nContent-Length: 3\r\n\r\nfoo";
    var msgs = try f.feed(allocator, raw);
    defer {
        for (msgs.items) |m| allocator.free(m);
        msgs.deinit(allocator);
    }

    try std.testing.expectEqual(@as(usize, 1), msgs.items.len);
    try std.testing.expectEqualStrings("foo", msgs.items[0]);
}

test "Framer: round-trip frame then feed" {
    const allocator = std.testing.allocator;
    var f = Framer.init();
    defer f.deinit(allocator);

    const body = "{\"id\":1,\"method\":\"test\"}";
    const framed = try Framer.frame(allocator, body);
    defer allocator.free(framed);

    var msgs = try f.feed(allocator, framed);
    defer {
        for (msgs.items) |m| allocator.free(m);
        msgs.deinit(allocator);
    }

    try std.testing.expectEqual(@as(usize, 1), msgs.items.len);
    try std.testing.expectEqualStrings(body, msgs.items[0]);
}
