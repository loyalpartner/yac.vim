const std = @import("std");

const Allocator = std.mem.Allocator;

/// Generic newline-delimited framer: feed raw bytes, extract complete lines.
/// Lines are slices into the internal buffer — valid until next feed() call.
/// Multiple nextLine() calls between feeds are safe (cursor advances, no copy).
pub const LineFramer = struct {
    buf: std.ArrayListUnmanaged(u8) = .{},
    /// Start of unconsumed data. Compacted on next feed().
    start: usize = 0,
    max_size: usize,

    pub fn init(max_size: usize) LineFramer {
        return .{ .max_size = max_size };
    }

    pub fn deinit(self: *LineFramer, allocator: Allocator) void {
        self.buf.deinit(allocator);
    }

    /// Append raw data to the internal buffer.
    /// Compacts consumed data first, then appends.
    /// Returns error.Overflow if the buffer would exceed max_size.
    pub fn feed(self: *LineFramer, allocator: Allocator, data: []const u8) error{ Overflow, OutOfMemory }!void {
        // Compact: move unconsumed data to front
        if (self.start > 0) {
            const remaining = self.buf.items.len - self.start;
            if (remaining > 0) {
                std.mem.copyForwards(u8, self.buf.items[0..remaining], self.buf.items[self.start..]);
            }
            self.buf.shrinkRetainingCapacity(remaining);
            self.start = 0;
        }
        if (self.buf.items.len + data.len > self.max_size) return error.Overflow;
        try self.buf.appendSlice(allocator, data);
    }

    /// Extract the next complete line (without trailing \n).
    /// Returned slice is valid until the next feed() call.
    /// Returns null when no complete line is available.
    pub fn nextLine(self: *LineFramer) ?[]const u8 {
        const data = self.buf.items[self.start..];
        const pos = std.mem.indexOf(u8, data, "\n") orelse return null;
        const line = data[0..pos];
        self.start += pos + 1;
        return line;
    }

    pub fn len(self: *const LineFramer) usize {
        return self.buf.items.len - self.start;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "LineFramer: single complete line" {
    var f = LineFramer.init(1024);
    defer f.deinit(std.testing.allocator);

    try f.feed(std.testing.allocator, "hello\n");
    const line = f.nextLine().?;
    try std.testing.expectEqualStrings("hello", line);
    try std.testing.expectEqual(@as(?[]const u8, null), f.nextLine());
}

test "LineFramer: multiple lines in one feed" {
    var f = LineFramer.init(1024);
    defer f.deinit(std.testing.allocator);

    try f.feed(std.testing.allocator, "aaa\nbbb\nccc\n");
    try std.testing.expectEqualStrings("aaa", f.nextLine().?);
    try std.testing.expectEqualStrings("bbb", f.nextLine().?);
    try std.testing.expectEqualStrings("ccc", f.nextLine().?);
    try std.testing.expectEqual(@as(?[]const u8, null), f.nextLine());
}

test "LineFramer: partial line across feeds" {
    var f = LineFramer.init(1024);
    defer f.deinit(std.testing.allocator);

    try f.feed(std.testing.allocator, "hel");
    try std.testing.expectEqual(@as(?[]const u8, null), f.nextLine());
    try f.feed(std.testing.allocator, "lo\n");
    try std.testing.expectEqualStrings("hello", f.nextLine().?);
}

test "LineFramer: empty line" {
    var f = LineFramer.init(1024);
    defer f.deinit(std.testing.allocator);

    try f.feed(std.testing.allocator, "\n");
    const line = f.nextLine().?;
    try std.testing.expectEqual(@as(usize, 0), line.len);
}

test "LineFramer: overflow returns error" {
    var f = LineFramer.init(8);
    defer f.deinit(std.testing.allocator);

    try f.feed(std.testing.allocator, "12345678");
    try std.testing.expectError(error.Overflow, f.feed(std.testing.allocator, "9"));
}

test "LineFramer: data after partial consume" {
    var f = LineFramer.init(1024);
    defer f.deinit(std.testing.allocator);

    try f.feed(std.testing.allocator, "first\nsecond");
    try std.testing.expectEqualStrings("first", f.nextLine().?);
    try std.testing.expectEqual(@as(?[]const u8, null), f.nextLine());
    // Complete the second line
    try f.feed(std.testing.allocator, "\n");
    try std.testing.expectEqualStrings("second", f.nextLine().?);
}

test "LineFramer: compaction on feed" {
    var f = LineFramer.init(16);
    defer f.deinit(std.testing.allocator);

    // Fill near capacity
    try f.feed(std.testing.allocator, "aaaa\nbbbbbbbb");
    _ = f.nextLine(); // consume "aaaa", start=5
    // Without compaction, next feed of 4 bytes would overflow (13+4=17 > 16).
    // With compaction, remaining is 8 bytes, so 8+4=12 fits.
    try f.feed(std.testing.allocator, "cccc");
    try std.testing.expectEqual(@as(usize, 0), f.start);
}
