const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const vim = @import("vim/root.zig");
const protocol = vim.protocol;
const VimChannel = vim.VimChannel;

// ============================================================================
// Notifier — handler -> Vim push abstraction
//
// Handlers don't depend on VimServer directly. They push notifications
// through the Notifier, which broadcasts to all connected VimChannels.
// ============================================================================

pub const Notifier = struct {
    allocator: Allocator,
    io: Io,
    channels: std.ArrayList(*VimChannel),
    lock: Io.Mutex = .init,

    pub fn init(allocator: Allocator, io: Io) Notifier {
        return .{
            .allocator = allocator,
            .io = io,
            .channels = .empty,
        };
    }

    pub fn deinit(self: *Notifier) void {
        self.channels.deinit(self.allocator);
    }

    /// Register a VimChannel for receiving pushes.
    pub fn addChannel(self: *Notifier, ch: *VimChannel) void {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        self.channels.append(self.allocator, ch) catch {};
    }

    /// Unregister a VimChannel.
    pub fn removeChannel(self: *Notifier, ch: *VimChannel) void {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        for (self.channels.items, 0..) |c, i| {
            if (c == ch) {
                _ = self.channels.swapRemove(i);
                return;
            }
        }
    }

    /// Broadcast a typed notification to all connected Vim clients.
    /// Direct serialization: typed struct → wire bytes in one pass (no json.Value intermediate).
    pub fn send(self: *Notifier, comptime action: []const u8, params: vim.types.ParamsType(action)) !void {
        const encoded = try protocol.encodeNotificationTyped(self.allocator, action, params);
        defer self.allocator.free(encoded);

        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        for (self.channels.items) |ch| {
            const copy = ch.allocator.dupe(u8, encoded) catch continue;
            ch.send(copy) catch {
                ch.allocator.free(copy);
            };
        }
    }
};

// ============================================================================
// Tests
// ============================================================================

fn testIo() Io {
    const S = struct {
        var threaded: Io.Threaded = .init_single_threaded;
    };
    return S.threaded.io();
}

test "Notifier: send broadcasts to all channels" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = testIo();

    var notifier = Notifier.init(allocator, io);
    defer notifier.deinit();

    var ch1 = VimChannel.init(allocator, io);
    defer ch1.deinit();
    var ch2 = VimChannel.init(allocator, io);
    defer ch2.deinit();

    notifier.addChannel(&ch1);
    notifier.addChannel(&ch2);

    try notifier.send("log_message", .{ .level = 3, .message = "hello" });

    // Both channels should have one inbound notification via outbound
    const items1 = ch1.outbound.drain() orelse return error.TestExpectedItems;
    try std.testing.expectEqual(@as(usize, 1), items1.len);

    const items2 = ch2.outbound.drain() orelse return error.TestExpectedItems;
    try std.testing.expectEqual(@as(usize, 1), items2.len);
}

test "Notifier: removeChannel stops broadcasts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = testIo();

    var notifier = Notifier.init(allocator, io);
    defer notifier.deinit();

    var ch1 = VimChannel.init(allocator, io);
    defer ch1.deinit();

    notifier.addChannel(&ch1);
    notifier.removeChannel(&ch1);

    try notifier.send("log_message", .{ .level = 3, .message = "hello" });

    // Channel should be empty after removal
    try std.testing.expect(ch1.outbound.drain() == null);
}
