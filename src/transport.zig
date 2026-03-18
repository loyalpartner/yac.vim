const std = @import("std");
const queue_mod = @import("queue.zig");
const vim = @import("vim_protocol.zig");
const json = @import("json_utils.zig");
const log = std.log.scoped(.transport);

const Allocator = std.mem.Allocator;
const Value = json.Value;

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
        readMessage: *const fn (*Transport, Allocator) ReadError!?[]u8,
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

    // ── Convenience methods (serialize Vim channel protocol, then call writeMessage) ──

    /// Send a JSON-RPC response: [vim_id, result]
    pub fn writeResponse(self: *Transport, alloc: Allocator, vim_id: u64, result: Value) void {
        const encoded = vim.encodeJsonRpcResponse(alloc, @as(i64, @intCast(vim_id)), result) catch return;
        defer alloc.free(encoded);
        self.writeMessage(encoded) catch {};
    }

    /// Send a Vim ex command: ["ex", command]
    pub fn writeEx(self: *Transport, alloc: Allocator, command: []const u8) void {
        const encoded = vim.encodeChannelCommand(alloc, .{ .ex = .{ .command = command } }) catch return;
        defer alloc.free(encoded);
        self.writeMessage(encoded) catch {};
    }

    /// Send a Vim call (fire-and-forget): ["call", func, args]
    pub fn writeCallAsync(self: *Transport, alloc: Allocator, func: []const u8, args: Value) void {
        const encoded = vim.encodeChannelCommand(alloc, .{ .call_async = .{ .func = func, .args = args } }) catch return;
        defer alloc.free(encoded);
        self.writeMessage(encoded) catch {};
    }

    /// Send a Vim expr request: ["expr", expr, id]
    pub fn writeExpr(self: *Transport, alloc: Allocator, expr: []const u8, id: i64) void {
        const encoded = vim.encodeChannelCommand(alloc, .{ .expr = .{ .expr = expr, .id = id } }) catch return;
        defer alloc.free(encoded);
        self.writeMessage(encoded) catch {};
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
    interface: Transport,
    stream: std.net.Stream,
    recv_buf: std.ArrayList(u8),
    out_queue: *queue_mod.OutQueue,
    gpa: Allocator,

    const vtable_impl: Transport.VTable = .{
        .readMessage = vtableReadMessage,
        .writeMessage = vtableWriteMessage,
    };

    pub fn init(gpa: Allocator, stream: std.net.Stream, out_queue: *queue_mod.OutQueue) UnixSocketTransport {
        return .{
            .interface = .{ .vtable = &vtable_impl },
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
    pub fn feedInput(self: *UnixSocketTransport, data: []const u8) Allocator.Error!void {
        try self.recv_buf.appendSlice(self.gpa, data);
    }

    /// Check if adding `incoming` bytes would exceed the buffer limit.
    pub fn wouldOverflow(self: *const UnixSocketTransport, incoming: usize) bool {
        return self.recv_buf.items.len + incoming > MAX_RECV_BUF;
    }

    /// Get the Transport vtable interface (for code that needs *Transport).
    pub fn asTransport(self: *UnixSocketTransport) *Transport {
        return &self.interface;
    }

    /// Get the underlying stream handle (for poll fd construction).
    pub fn getHandle(self: *const UnixSocketTransport) std.posix.fd_t {
        return self.stream.handle;
    }

    // ── Public methods (direct call, no vtable overhead) ──

    /// Extract one complete \n-delimited message from the receive buffer.
    /// Returns null if no complete message is available.
    pub fn readMessage(self: *UnixSocketTransport, alloc: Allocator) Transport.ReadError!?[]u8 {
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

    /// Send a complete JSON message. Appends \n, GPA-allocates, pushes to OutQueue.
    pub fn writeMessage(self: *UnixSocketTransport, json_bytes: []const u8) Transport.WriteError!void {
        const msg = try self.gpa.alloc(u8, json_bytes.len + 1);
        @memcpy(msg[0..json_bytes.len], json_bytes);
        msg[json_bytes.len] = '\n';

        if (!self.out_queue.push(.{ .stream = self.stream, .bytes = msg })) {
            self.gpa.free(msg);
            log.warn("Transport: out queue full, dropping message", .{});
        }
    }

    // ── vtable trampolines ──

    fn vtableReadMessage(t: *Transport, alloc: Allocator) Transport.ReadError!?[]u8 {
        return @as(*UnixSocketTransport, @fieldParentPtr("interface", t)).readMessage(alloc);
    }

    fn vtableWriteMessage(t: *Transport, json_bytes: []const u8) Transport.WriteError!void {
        return @as(*UnixSocketTransport, @fieldParentPtr("interface", t)).writeMessage(json_bytes);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "UnixSocketTransport: readMessage extracts newline-delimited lines" {
    var out_queue: queue_mod.OutQueue = .{};
    var t = UnixSocketTransport.init(std.testing.allocator, .{ .handle = -1 }, &out_queue);
    defer t.deinit();

    try t.feedInput("hello");
    try std.testing.expect(try t.readMessage(std.testing.allocator) == null);

    try t.feedInput(" world\n");
    const r = (try t.readMessage(std.testing.allocator)).?;
    defer std.testing.allocator.free(r);
    try std.testing.expectEqualStrings("hello world", r);

    try std.testing.expect(try t.readMessage(std.testing.allocator) == null);
}

test "UnixSocketTransport: readMessage handles multiple lines" {
    var out_queue: queue_mod.OutQueue = .{};
    var t = UnixSocketTransport.init(std.testing.allocator, .{ .handle = -1 }, &out_queue);
    defer t.deinit();

    try t.feedInput("line1\nline2\nline3\n");

    const r1 = (try t.readMessage(std.testing.allocator)).?;
    defer std.testing.allocator.free(r1);
    try std.testing.expectEqualStrings("line1", r1);

    const r2 = (try t.readMessage(std.testing.allocator)).?;
    defer std.testing.allocator.free(r2);
    try std.testing.expectEqualStrings("line2", r2);

    const r3 = (try t.readMessage(std.testing.allocator)).?;
    defer std.testing.allocator.free(r3);
    try std.testing.expectEqualStrings("line3", r3);

    try std.testing.expect(try t.readMessage(std.testing.allocator) == null);
}

test "UnixSocketTransport: readMessage skips empty lines" {
    var out_queue: queue_mod.OutQueue = .{};
    var t = UnixSocketTransport.init(std.testing.allocator, .{ .handle = -1 }, &out_queue);
    defer t.deinit();

    try t.feedInput("\n\ndata\n\n");

    try std.testing.expect(try t.readMessage(std.testing.allocator) == null);
    try std.testing.expect(try t.readMessage(std.testing.allocator) == null);

    const r = (try t.readMessage(std.testing.allocator)).?;
    defer std.testing.allocator.free(r);
    try std.testing.expectEqualStrings("data", r);
}

test "UnixSocketTransport: writeMessage pushes to OutQueue" {
    var out_queue: queue_mod.OutQueue = .{};
    var t = UnixSocketTransport.init(std.testing.allocator, .{ .handle = -1 }, &out_queue);
    defer t.deinit();

    try t.writeMessage("[1,\"ok\"]");

    const msg = out_queue.pop() orelse unreachable;
    defer msg.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("[1,\"ok\"]\n", msg.bytes);
}

test "UnixSocketTransport: vtable dispatch works" {
    var out_queue: queue_mod.OutQueue = .{};
    var t = UnixSocketTransport.init(std.testing.allocator, .{ .handle = -1 }, &out_queue);
    defer t.deinit();

    // Write via vtable
    try t.interface.writeMessage("[2,\"hi\"]");

    const msg = out_queue.pop() orelse unreachable;
    defer msg.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("[2,\"hi\"]\n", msg.bytes);

    // Read via vtable
    try t.feedInput("test\n");
    const r = (try t.interface.readMessage(std.testing.allocator)).?;
    defer std.testing.allocator.free(r);
    try std.testing.expectEqualStrings("test", r);
}

test "UnixSocketTransport: wouldOverflow" {
    var out_queue: queue_mod.OutQueue = .{};
    var t = UnixSocketTransport.init(std.testing.allocator, .{ .handle = -1 }, &out_queue);
    defer t.deinit();

    try std.testing.expect(!t.wouldOverflow(100));
    try std.testing.expect(t.wouldOverflow(MAX_RECV_BUF + 1));
}
