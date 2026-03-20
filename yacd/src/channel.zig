const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Queue = @import("queue.zig").Queue;

/// Bidirectional communication channel.
/// - reader coroutine: reads from IO source -> pushes to inbound queue
/// - writer coroutine: drains outbound queue -> writes to IO sink
/// - Users interact via inbound/outbound queues
pub fn Channel(comptime InMsg: type, comptime OutMsg: type) type {
    return struct {
        const Self = @This();

        inbound: Queue(InMsg),
        outbound: Queue(OutMsg),
        io: Io,
        allocator: Allocator,

        /// Reader function: read from IO, return parsed message or null to stop.
        pub const ReadFn = *const fn (*anyopaque, Io) ?InMsg;
        /// Writer function: write a message to IO.
        pub const WriteFn = *const fn (*anyopaque, Io, OutMsg) void;

        pub fn init(allocator: Allocator, io: Io) Self {
            return .{
                .inbound = Queue(InMsg).init(allocator, io),
                .outbound = Queue(OutMsg).init(allocator, io),
                .io = io,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.inbound.deinit();
            self.outbound.deinit();
        }

        /// Start reader and writer coroutines in the given Io.Group.
        pub fn start(
            self: *Self,
            group: *Io.Group,
            read_ctx: *anyopaque,
            read_fn: ReadFn,
            write_ctx: *anyopaque,
            write_fn: WriteFn,
        ) void {
            group.concurrent(self.io, readerLoop, .{ self, read_ctx, read_fn }) catch {};
            group.concurrent(self.io, writerLoop, .{ self, write_ctx, write_fn }) catch {};
        }

        /// Send a message (push to outbound queue).
        pub fn send(self: *Self, msg: OutMsg) !void {
            try self.outbound.send(msg);
        }

        /// Drain inbound messages. Caller owns the returned slice.
        pub fn recv(self: *Self) ?[]InMsg {
            return self.inbound.drain();
        }

        /// Wait for inbound messages to be available (cancelable).
        pub fn waitInbound(self: *Self) Io.Cancelable!void {
            try self.inbound.wait();
        }

        // -- internal coroutines --

        fn readerLoop(self: *Self, ctx: *anyopaque, read_fn: ReadFn) Io.Cancelable!void {
            while (true) {
                const msg = read_fn(ctx, self.io) orelse return;
                self.inbound.send(msg) catch return;
            }
        }

        fn writerLoop(self: *Self, ctx: *anyopaque, write_fn: WriteFn) Io.Cancelable!void {
            while (true) {
                self.outbound.wait() catch return;
                if (self.outbound.drain()) |items| {
                    defer self.allocator.free(items);
                    for (items) |msg| {
                        write_fn(ctx, self.io, msg);
                    }
                }
            }
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

const TestMsg = struct {
    value: u32,
};

fn testIo() Io {
    const S = struct {
        var threaded: Io.Threaded = .init_single_threaded;
    };
    return S.threaded.io();
}

test "Channel: reader pushes to inbound" {
    const allocator = std.testing.allocator;
    const io = testIo();

    var ch = Channel(TestMsg, TestMsg).init(allocator, io);
    defer ch.deinit();

    // Simulate reader by directly pushing to inbound
    try ch.inbound.send(.{ .value = 10 });
    try ch.inbound.send(.{ .value = 20 });

    const msgs = ch.recv() orelse return error.TestExpectedMessages;
    defer allocator.free(msgs);

    try std.testing.expectEqual(@as(usize, 2), msgs.len);
    try std.testing.expectEqual(@as(u32, 10), msgs[0].value);
    try std.testing.expectEqual(@as(u32, 20), msgs[1].value);
}

test "Channel: send pushes to outbound" {
    const allocator = std.testing.allocator;
    const io = testIo();

    var ch = Channel(TestMsg, TestMsg).init(allocator, io);
    defer ch.deinit();

    try ch.send(.{ .value = 100 });
    try ch.send(.{ .value = 200 });

    const msgs = ch.outbound.drain() orelse return error.TestExpectedMessages;
    defer allocator.free(msgs);

    try std.testing.expectEqual(@as(usize, 2), msgs.len);
    try std.testing.expectEqual(@as(u32, 100), msgs[0].value);
    try std.testing.expectEqual(@as(u32, 200), msgs[1].value);
}

test "Channel: recv returns null when empty" {
    const allocator = std.testing.allocator;
    const io = testIo();

    var ch = Channel(TestMsg, TestMsg).init(allocator, io);
    defer ch.deinit();

    try std.testing.expect(ch.recv() == null);
}

test "Channel: inbound and outbound are independent" {
    const allocator = std.testing.allocator;
    const io = testIo();

    var ch = Channel(TestMsg, TestMsg).init(allocator, io);
    defer ch.deinit();

    // Push to inbound
    try ch.inbound.send(.{ .value = 1 });
    // Push to outbound
    try ch.send(.{ .value = 2 });

    const in_msgs = ch.recv() orelse return error.TestExpectedMessages;
    defer allocator.free(in_msgs);
    const out_msgs = ch.outbound.drain() orelse return error.TestExpectedMessages;
    defer allocator.free(out_msgs);

    try std.testing.expectEqual(@as(u32, 1), in_msgs[0].value);
    try std.testing.expectEqual(@as(u32, 2), out_msgs[0].value);
}
