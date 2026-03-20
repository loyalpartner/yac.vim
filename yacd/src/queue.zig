const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// Thread-safe MPSC queue using Io.Mutex + Io.Event.
/// Multiple producers can push concurrently; a single consumer drains.
pub fn Queue(comptime T: type) type {
    return struct {
        const Self = @This();

        allocator: Allocator,
        io: Io,
        items: std.ArrayList(T),
        lock: Io.Mutex = .init,
        event: Io.Event = .unset,

        pub fn init(allocator: Allocator, io: Io) Self {
            return .{
                .allocator = allocator,
                .io = io,
                .items = .empty,
            };
        }

        pub fn deinit(self: *Self) void {
            self.items.deinit(self.allocator);
        }

        /// Push an item (thread-safe, non-blocking for other producers).
        pub fn push(self: *Self, item: T) !void {
            self.lock.lockUncancelable(self.io);
            defer self.lock.unlock(self.io);
            try self.items.append(self.allocator, item);
        }

        /// Wait until at least one item is available (cancelable).
        pub fn wait(self: *Self) Io.Cancelable!void {
            try self.event.wait(self.io);
        }

        /// Drain all pending items. Caller owns the returned slice
        /// and must free it with self.allocator.
        pub fn drain(self: *Self) ?[]T {
            self.lock.lockUncancelable(self.io);
            defer self.lock.unlock(self.io);

            if (self.items.items.len == 0) return null;

            const slice = self.items.toOwnedSlice(self.allocator) catch return null;
            // Reset event so next wait blocks until new items arrive
            self.event = .unset;
            return slice;
        }

        /// Push + signal in one call (convenience for producers).
        pub fn send(self: *Self, item: T) !void {
            self.lock.lockUncancelable(self.io);
            defer self.lock.unlock(self.io);
            try self.items.append(self.allocator, item);
            self.event.set(self.io);
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

fn testIo() Io {
    const S = struct {
        var threaded: Io.Threaded = .init_single_threaded;
    };
    return S.threaded.io();
}

test "Queue: push and drain" {
    const io = testIo();
    const allocator = std.testing.allocator;
    var q = Queue(u32).init(allocator, io);
    defer q.deinit();

    try q.push(1);
    try q.push(2);
    try q.push(3);

    const items = q.drain() orelse return error.TestExpectedItems;
    defer allocator.free(items);

    try std.testing.expectEqual(@as(usize, 3), items.len);
    try std.testing.expectEqual(@as(u32, 1), items[0]);
    try std.testing.expectEqual(@as(u32, 2), items[1]);
    try std.testing.expectEqual(@as(u32, 3), items[2]);
}

test "Queue: drain empty returns null" {
    const io = testIo();
    const allocator = std.testing.allocator;
    var q = Queue(u32).init(allocator, io);
    defer q.deinit();

    try std.testing.expect(q.drain() == null);
}

test "Queue: drain clears items" {
    const io = testIo();
    const allocator = std.testing.allocator;
    var q = Queue(u32).init(allocator, io);
    defer q.deinit();

    try q.push(10);
    const first = q.drain() orelse return error.TestExpectedItems;
    defer allocator.free(first);

    try std.testing.expectEqual(@as(usize, 1), first.len);

    // Second drain should be empty
    try std.testing.expect(q.drain() == null);
}

test "Queue: send sets event" {
    const io = testIo();
    const allocator = std.testing.allocator;
    var q = Queue(u32).init(allocator, io);
    defer q.deinit();

    try q.send(42);

    const items = q.drain() orelse return error.TestExpectedItems;
    defer allocator.free(items);

    try std.testing.expectEqual(@as(usize, 1), items.len);
    try std.testing.expectEqual(@as(u32, 42), items[0]);
}

test "Queue: multiple sends then drain preserves FIFO order" {
    const io = testIo();
    const allocator = std.testing.allocator;
    var q = Queue(u32).init(allocator, io);
    defer q.deinit();

    try q.send(1);
    try q.send(2);
    try q.send(3);

    const items = q.drain() orelse return error.TestExpectedItems;
    defer allocator.free(items);

    try std.testing.expectEqual(@as(usize, 3), items.len);
    try std.testing.expectEqual(@as(u32, 1), items[0]);
    try std.testing.expectEqual(@as(u32, 2), items[1]);
    try std.testing.expectEqual(@as(u32, 3), items[2]);
}

test "Queue: event resets after drain" {
    const io = testIo();
    const allocator = std.testing.allocator;
    var q = Queue(u32).init(allocator, io);
    defer q.deinit();

    try q.send(1);
    // Event should be set
    try std.testing.expect(q.event.isSet());

    const items = q.drain() orelse return error.TestExpectedItems;
    defer allocator.free(items);

    // Event should be reset after drain
    try std.testing.expect(!q.event.isSet());
}
