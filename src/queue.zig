const std = @import("std");
const clients_mod = @import("clients.zig");

const Allocator = std.mem.Allocator;
pub const ClientId = clients_mod.ClientId;

// ============================================================================
// Generic bounded queue — Mutex + Condition variables, fixed capacity.
// push() drops the item and returns false when full (non-blocking).
// pop() blocks until an item is available or the queue is closed.
// ============================================================================

pub fn BoundedQueue(comptime T: type, comptime capacity: usize) type {
    return struct {
        const Self = @This();

        buf: [capacity]T = undefined,
        head: usize = 0,
        tail: usize = 0,
        count: usize = 0,
        closed: bool = false,
        mutex: std.Thread.Mutex = .{},
        not_empty: std.Thread.Condition = .{},

        /// Push an item. Returns false (dropping the item) when full or closed.
        pub fn push(self: *Self, item: T) bool {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.closed or self.count == capacity) return false;
            self.buf[self.tail] = item;
            self.tail = (self.tail + 1) % capacity;
            self.count += 1;
            self.not_empty.signal();
            return true;
        }

        /// Block until an item is available, then return it.
        /// Returns null when the queue is closed and empty.
        pub fn pop(self: *Self) ?T {
            self.mutex.lock();
            defer self.mutex.unlock();
            while (self.count == 0 and !self.closed) {
                self.not_empty.wait(&self.mutex);
            }
            if (self.count == 0) return null;
            const item = self.buf[self.head];
            self.head = (self.head + 1) % capacity;
            self.count -= 1;
            return item;
        }

        /// Close the queue. Wakes all blocked pop() callers.
        pub fn close(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.closed = true;
            self.not_empty.broadcast();
        }
    };
}

// ============================================================================
// Envelope — a raw Vim JSON-RPC line routed from the main thread to workers.
// raw_line is GPA-allocated; the worker that processes it must free it.
// ============================================================================

pub const Envelope = struct {
    client_id: ClientId,
    /// The stream is captured at routing time so workers never need to
    /// look up the client in the shared clients map.
    client_stream: std.net.Stream,
    /// GPA-allocated copy of the trimmed JSON line (no newline).
    raw_line: []u8,

    pub fn deinit(self: Envelope, allocator: Allocator) void {
        allocator.free(self.raw_line);
    }
};

// ============================================================================
// Frame — a serialised message to be written to a Vim socket.
// bytes is GPA-allocated; the writer thread frees it after writing.
// ============================================================================

pub const Frame = struct {
    stream: std.net.Stream,
    bytes: []u8,

    pub fn deinit(self: Frame, allocator: Allocator) void {
        allocator.free(self.bytes);
    }
};

// ============================================================================
// Queue type aliases
// ============================================================================

pub const RecvChannel = BoundedQueue(Envelope, 1024);
pub const SendChannel = BoundedQueue(Frame, 4096);

// ============================================================================
// TS method routing — fast byte-scan, no JSON parsing required.
// Methods that require exclusive TreeSitter access go to the TS thread.
// ============================================================================

const TS_METHODS = [_][]const u8{
    "\"ts_symbols\"",
    "\"ts_folding\"",
    "\"ts_highlights\"",
    "\"ts_navigate\"",
    "\"ts_textobjects\"",
    "\"ts_hover_highlight\"",
    "\"load_language\"",
};

/// Returns true if raw_line contains a TS-related method name.
pub fn isTsMethod(raw_line: []const u8) bool {
    for (TS_METHODS) |kw| {
        if (std.mem.indexOf(u8, raw_line, kw) != null) return true;
    }
    return false;
}

// DAP action methods — lightweight commands forwarded to adapter.
// Processed inline in the main loop to avoid work-queue round trip.
const DAP_ACTION_METHODS = [_][]const u8{
    "\"dap_next\"",
    "\"dap_step_in\"",
    "\"dap_step_out\"",
    "\"dap_continue\"",
};

/// Returns true if raw_line contains a DAP action method (step/continue).
pub fn isDapActionMethod(raw_line: []const u8) bool {
    for (DAP_ACTION_METHODS) |kw| {
        if (std.mem.indexOf(u8, raw_line, kw) != null) return true;
    }
    return false;
}

// ============================================================================
// Tests
// ============================================================================

test "isTsMethod — returns true for all known TS methods" {
    try std.testing.expect(isTsMethod("[1, \"ts_symbols\", {}]"));
    try std.testing.expect(isTsMethod("[1, \"ts_folding\", {}]"));
    try std.testing.expect(isTsMethod("[1, \"ts_highlights\", {}]"));
    try std.testing.expect(isTsMethod("[1, \"ts_navigate\", {}]"));
    try std.testing.expect(isTsMethod("[1, \"ts_textobjects\", {}]"));
    try std.testing.expect(isTsMethod("[1, \"ts_hover_highlight\", {}]"));
    try std.testing.expect(isTsMethod("[1, \"load_language\", {}]"));
}

test "isTsMethod — returns false for non-TS methods" {
    try std.testing.expect(!isTsMethod("\"textDocument/completion\""));
    try std.testing.expect(!isTsMethod("\"textDocument/definition\""));
    try std.testing.expect(!isTsMethod("\"formatting\""));
    try std.testing.expect(!isTsMethod("\"references\""));
    try std.testing.expect(!isTsMethod(""));
    // Partial match without quotes should not match
    try std.testing.expect(!isTsMethod("ts_symbols"));
}

test "isTsMethod — substring in larger line" {
    try std.testing.expect(isTsMethod("[1, \"ts_highlights\", {\"file\": \"/tmp/test.zig\"}]"));
    try std.testing.expect(!isTsMethod("[1, \"completion\", {\"file\": \"/tmp/test.zig\"}]"));
}

test "BoundedQueue — push and pop basic behavior" {
    const Q = BoundedQueue(u32, 4);
    var q = Q{};
    try std.testing.expect(q.push(10));
    try std.testing.expect(q.push(20));
    try std.testing.expect(q.push(30));
    try std.testing.expectEqual(@as(?u32, 10), q.pop());
    try std.testing.expectEqual(@as(?u32, 20), q.pop());
    try std.testing.expectEqual(@as(?u32, 30), q.pop());
}

test "BoundedQueue — push returns false when full" {
    const Q = BoundedQueue(u32, 2);
    var q = Q{};
    try std.testing.expect(q.push(1));
    try std.testing.expect(q.push(2));
    // Queue is full now
    try std.testing.expect(!q.push(3));
    // Pop one and push again should work
    try std.testing.expectEqual(@as(?u32, 1), q.pop());
    try std.testing.expect(q.push(4));
}

test "BoundedQueue — close makes pop return null on empty" {
    const Q = BoundedQueue(u32, 4);
    var q = Q{};
    try std.testing.expect(q.push(42));
    q.close();
    // Should still return items that were pushed before close
    try std.testing.expectEqual(@as(?u32, 42), q.pop());
    // Now empty + closed → null
    try std.testing.expectEqual(@as(?u32, null), q.pop());
}

test "BoundedQueue — push returns false when closed" {
    const Q = BoundedQueue(u32, 4);
    var q = Q{};
    q.close();
    try std.testing.expect(!q.push(1));
}

test "RecvChannel capacity is 1024" {
    const q = RecvChannel{};
    try std.testing.expectEqual(@as(usize, 1024), q.buf.len);
}

test "SendChannel capacity is 4096" {
    const q = SendChannel{};
    try std.testing.expectEqual(@as(usize, 4096), q.buf.len);
}

test "BoundedQueue — wraps around correctly" {
    const Q = BoundedQueue(u32, 3);
    var q = Q{};
    // Fill and drain to advance head/tail pointers
    try std.testing.expect(q.push(1));
    try std.testing.expect(q.push(2));
    try std.testing.expectEqual(@as(?u32, 1), q.pop());
    try std.testing.expectEqual(@as(?u32, 2), q.pop());
    // Now head=2, tail=2, push 3 items wrapping around
    try std.testing.expect(q.push(10));
    try std.testing.expect(q.push(20));
    try std.testing.expect(q.push(30));
    try std.testing.expectEqual(@as(?u32, 10), q.pop());
    try std.testing.expectEqual(@as(?u32, 20), q.pop());
    try std.testing.expectEqual(@as(?u32, 30), q.pop());
}
