const std = @import("std");
const queue_mod = @import("queue.zig");
const log = @import("log.zig");

const Allocator = std.mem.Allocator;

// ============================================================================
// Transport — vtable interface for Vim channel communication.
//
// Abstracts the framing protocol (newline-delimited JSON) and IO mechanism
// so that handlers and dispatch logic are transport-agnostic.
//
// Implementations:
//   - UnixSocketTransport: Unix domain socket (Linux/macOS)
//   - (future) NamedPipeTransport: Windows named pipes
//   - (future) StdioTransport: stdin/stdout for debugging
// ============================================================================

pub const Transport = struct {
    vtable: *const VTable,

    pub const VTable = struct {
        /// Extract one complete message from the transport's internal buffer.
        /// Returns null if no complete message is available yet.
        /// Caller owns the returned slice (allocated with `alloc`).
        readMessage: *const fn (*Transport, Allocator) ReadError!?[]u8,

        /// Send a complete JSON message through the transport.
        /// The transport handles framing (e.g., appending \n).
        writeMessage: *const fn (*Transport, []const u8) WriteError!void,
    };

    pub const ReadError = Allocator.Error;
    pub const WriteError = Allocator.Error;

    pub fn readMessage(self: *Transport, alloc: Allocator) ReadError!?[]u8 {
        return self.vtable.readMessage(self, alloc);
    }

    pub fn writeMessage(self: *Transport, json_bytes: []const u8) WriteError!void {
        return self.vtable.writeMessage(self, json_bytes);
    }
};

// ============================================================================
// UnixSocketTransport — Transport over Unix domain sockets.
//
// Read: poll loop feeds data via feedInput(); readMessage() extracts \n lines.
// Write: GPA-allocates bytes + \n, pushes to OutQueue for async writer thread.
// ============================================================================

/// Maximum bytes buffered before the connection is dropped (OOM protection).
pub const MAX_RECV_BUF: usize = 4 * 1024 * 1024; // 4 MB

pub const UnixSocketTransport = struct {
    transport: Transport,
    stream: std.net.Stream,
    recv_buf: std.ArrayList(u8),
    out_queue: *queue_mod.OutQueue,
    gpa: Allocator,

    const vtable_impl: Transport.VTable = .{
        .readMessage = readMessage,
        .writeMessage = writeMessage,
    };

    pub fn init(gpa: Allocator, stream: std.net.Stream, out_queue: *queue_mod.OutQueue) UnixSocketTransport {
        return .{
            .transport = .{ .vtable = &vtable_impl },
            .stream = stream,
            .recv_buf = .{},
            .out_queue = out_queue,
            .gpa = gpa,
        };
    }

    pub fn deinit(self: *UnixSocketTransport) void {
        self.recv_buf.deinit(self.gpa);
    }

    /// Feed raw bytes from socket read into the receive buffer.
    /// Called by the poll loop after socket.read().
    pub fn feedInput(self: *UnixSocketTransport, data: []const u8) Allocator.Error!void {
        try self.recv_buf.appendSlice(self.gpa, data);
    }

    /// Check if adding `incoming` bytes would exceed the buffer limit.
    pub fn wouldOverflow(self: *const UnixSocketTransport, incoming: usize) bool {
        return self.recv_buf.items.len + incoming > MAX_RECV_BUF;
    }

    /// Get the Transport vtable interface.
    pub fn asTransport(self: *UnixSocketTransport) *Transport {
        return &self.transport;
    }

    /// Get the underlying stream handle (for poll fd construction).
    pub fn getHandle(self: *const UnixSocketTransport) std.posix.fd_t {
        return self.stream.handle;
    }

    // ── vtable implementations ──

    fn readMessage(t: *Transport, alloc: Allocator) Transport.ReadError!?[]u8 {
        const self: *UnixSocketTransport = @fieldParentPtr("transport", t);

        const newline_pos = std.mem.indexOf(u8, self.recv_buf.items, "\n") orelse return null;

        const line = self.recv_buf.items[0..newline_pos];
        const result = if (line.len > 0) try alloc.dupe(u8, line) else null;

        // Remove processed line + \n from buffer
        const after = newline_pos + 1;
        const remaining = self.recv_buf.items.len - after;
        if (remaining > 0) {
            std.mem.copyForwards(u8, self.recv_buf.items[0..remaining], self.recv_buf.items[after..]);
        }
        self.recv_buf.shrinkRetainingCapacity(remaining);

        return result;
    }

    fn writeMessage(t: *Transport, json_bytes: []const u8) Transport.WriteError!void {
        const self: *UnixSocketTransport = @fieldParentPtr("transport", t);

        // GPA-allocate bytes + \n so they survive past the caller's arena.
        const msg = try self.gpa.alloc(u8, json_bytes.len + 1);
        @memcpy(msg[0..json_bytes.len], json_bytes);
        msg[json_bytes.len] = '\n';

        if (!self.out_queue.push(.{ .stream = self.stream, .bytes = msg })) {
            self.gpa.free(msg);
            log.warn("Transport: out queue full, dropping message", .{});
        }
    }
};

// ============================================================================
// Tests
// ============================================================================

test "UnixSocketTransport: readMessage extracts newline-delimited lines" {
    var out_queue: queue_mod.OutQueue = .{};
    var t = UnixSocketTransport.init(
        std.testing.allocator,
        .{ .handle = -1 },
        &out_queue,
    );
    defer t.deinit();

    // Feed partial data — no complete line yet
    try t.feedInput("hello");
    const r1 = try t.transport.readMessage(std.testing.allocator);
    try std.testing.expect(r1 == null);

    // Feed rest of line
    try t.feedInput(" world\n");
    const r2 = try t.transport.readMessage(std.testing.allocator);
    try std.testing.expect(r2 != null);
    defer std.testing.allocator.free(r2.?);
    try std.testing.expectEqualStrings("hello world", r2.?);

    // Buffer should be empty now
    const r3 = try t.transport.readMessage(std.testing.allocator);
    try std.testing.expect(r3 == null);
}

test "UnixSocketTransport: readMessage handles multiple lines" {
    var out_queue: queue_mod.OutQueue = .{};
    var t = UnixSocketTransport.init(
        std.testing.allocator,
        .{ .handle = -1 },
        &out_queue,
    );
    defer t.deinit();

    try t.feedInput("line1\nline2\nline3\n");

    const r1 = try t.transport.readMessage(std.testing.allocator);
    defer std.testing.allocator.free(r1.?);
    try std.testing.expectEqualStrings("line1", r1.?);

    const r2 = try t.transport.readMessage(std.testing.allocator);
    defer std.testing.allocator.free(r2.?);
    try std.testing.expectEqualStrings("line2", r2.?);

    const r3 = try t.transport.readMessage(std.testing.allocator);
    defer std.testing.allocator.free(r3.?);
    try std.testing.expectEqualStrings("line3", r3.?);

    const r4 = try t.transport.readMessage(std.testing.allocator);
    try std.testing.expect(r4 == null);
}

test "UnixSocketTransport: readMessage skips empty lines" {
    var out_queue: queue_mod.OutQueue = .{};
    var t = UnixSocketTransport.init(
        std.testing.allocator,
        .{ .handle = -1 },
        &out_queue,
    );
    defer t.deinit();

    try t.feedInput("\n\ndata\n\n");

    // First two \n produce empty lines → readMessage returns null for those
    // Actually, our implementation returns null for empty lines and removes them
    const r1 = try t.transport.readMessage(std.testing.allocator);
    try std.testing.expect(r1 == null); // empty line skipped

    const r2 = try t.transport.readMessage(std.testing.allocator);
    try std.testing.expect(r2 == null); // empty line skipped

    const r3 = try t.transport.readMessage(std.testing.allocator);
    defer std.testing.allocator.free(r3.?);
    try std.testing.expectEqualStrings("data", r3.?);
}

test "UnixSocketTransport: writeMessage pushes to OutQueue" {
    var out_queue: queue_mod.OutQueue = .{};
    var t = UnixSocketTransport.init(
        std.testing.allocator,
        .{ .handle = -1 },
        &out_queue,
    );
    defer t.deinit();

    try t.transport.writeMessage("[1,\"ok\"]");

    const msg = out_queue.pop() orelse unreachable;
    defer msg.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("[1,\"ok\"]\n", msg.bytes);
}

test "UnixSocketTransport: wouldOverflow" {
    var out_queue: queue_mod.OutQueue = .{};
    var t = UnixSocketTransport.init(
        std.testing.allocator,
        .{ .handle = -1 },
        &out_queue,
    );
    defer t.deinit();

    try std.testing.expect(!t.wouldOverflow(100));
    try std.testing.expect(t.wouldOverflow(MAX_RECV_BUF + 1));
}
