const std = @import("std");
const Allocator = std.mem.Allocator;

// ============================================================================
// LineFramer — newline-delimited message framing for Vim channel protocol.
//
// Accumulates raw bytes via feed(), then yields complete lines via next().
// Empty lines (consecutive \n) are skipped automatically.
//
// Returned slices point into the internal buffer and are invalidated by
// the next call to next() or feed(). Callers must copy if they need to
// retain the data (e.g. for async dispatch).
// ============================================================================

pub const LineFramer = struct {
    buf: std.ArrayList(u8) = .empty,
    /// Offset into buf where unprocessed data starts.
    start: usize = 0,

    pub fn deinit(self: *LineFramer, allocator: Allocator) void {
        self.buf.deinit(allocator);
    }

    /// Append raw bytes to the internal buffer.
    /// Compacts consumed data first to avoid unbounded growth.
    pub fn feed(self: *LineFramer, allocator: Allocator, data: []const u8) Allocator.Error!void {
        self.compact();
        try self.buf.appendSlice(allocator, data);
    }

    /// Extract the next complete line (without trailing \n).
    /// Returns null if no complete line is available.
    /// Skips empty lines.
    /// The returned slice is valid until the next call to next() or feed().
    pub fn next(self: *LineFramer) ?[]const u8 {
        while (std.mem.indexOf(u8, self.buf.items[self.start..], "\n")) |rel_pos| {
            const abs_pos = self.start + rel_pos;
            const line = self.buf.items[self.start..abs_pos];
            self.start = abs_pos + 1;

            if (line.len > 0) {
                return line;
            }
        }
        return null;
    }

    /// Compact: shift unprocessed data to front, reset start to 0.
    fn compact(self: *LineFramer) void {
        if (self.start == 0) return;
        const remaining = self.buf.items.len - self.start;
        if (remaining > 0) {
            std.mem.copyForwards(u8, self.buf.items[0..remaining], self.buf.items[self.start..]);
        }
        self.buf.shrinkRetainingCapacity(remaining);
        self.start = 0;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "LineFramer: feed + next extracts complete line" {
    var framer: LineFramer = .{};
    defer framer.deinit(std.testing.allocator);

    try framer.feed(std.testing.allocator, "hello world\n");
    const line = framer.next().?;
    try std.testing.expectEqualStrings("hello world", line);

    try std.testing.expect(framer.next() == null);
}

test "LineFramer: multiple lines in batch" {
    var framer: LineFramer = .{};
    defer framer.deinit(std.testing.allocator);

    try framer.feed(std.testing.allocator, "line1\nline2\nline3\n");

    try std.testing.expectEqualStrings("line1", framer.next().?);
    try std.testing.expectEqualStrings("line2", framer.next().?);
    try std.testing.expectEqualStrings("line3", framer.next().?);
    try std.testing.expect(framer.next() == null);
}

test "LineFramer: incomplete line returns null" {
    var framer: LineFramer = .{};
    defer framer.deinit(std.testing.allocator);

    try framer.feed(std.testing.allocator, "partial");
    try std.testing.expect(framer.next() == null);

    try framer.feed(std.testing.allocator, " data\n");
    try std.testing.expectEqualStrings("partial data", framer.next().?);
}

test "LineFramer: empty lines are skipped" {
    var framer: LineFramer = .{};
    defer framer.deinit(std.testing.allocator);

    try framer.feed(std.testing.allocator, "\n\ndata\n\n");

    try std.testing.expectEqualStrings("data", framer.next().?);
    try std.testing.expect(framer.next() == null);
}

test "LineFramer: line spanning multiple feeds" {
    var framer: LineFramer = .{};
    defer framer.deinit(std.testing.allocator);

    try framer.feed(std.testing.allocator, "hello");
    try std.testing.expect(framer.next() == null);

    try framer.feed(std.testing.allocator, " world\n");
    try std.testing.expectEqualStrings("hello world", framer.next().?);
}

test "LineFramer: mixed complete and incomplete" {
    var framer: LineFramer = .{};
    defer framer.deinit(std.testing.allocator);

    try framer.feed(std.testing.allocator, "first\nsec");
    try std.testing.expectEqualStrings("first", framer.next().?);
    try std.testing.expect(framer.next() == null);

    try framer.feed(std.testing.allocator, "ond\n");
    try std.testing.expectEqualStrings("second", framer.next().?);
}
