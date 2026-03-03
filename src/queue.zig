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
// WorkItem — a raw Vim JSON-RPC line routed from the main thread to workers.
// raw_line is GPA-allocated; the worker that processes it must free it.
// ============================================================================

pub const WorkItem = struct {
    client_id: ClientId,
    /// The stream is captured at routing time so workers never need to
    /// look up the client in the shared clients map.
    client_stream: std.net.Stream,
    /// GPA-allocated copy of the trimmed JSON line (no newline).
    raw_line: []u8,

    pub fn deinit(self: WorkItem, allocator: Allocator) void {
        allocator.free(self.raw_line);
    }
};

// ============================================================================
// OutMessage — a serialised message to be written to a Vim socket.
// bytes is GPA-allocated; the writer thread frees it after writing.
// ============================================================================

pub const OutMessage = struct {
    stream: std.net.Stream,
    bytes: []u8,

    pub fn deinit(self: OutMessage, allocator: Allocator) void {
        allocator.free(self.bytes);
    }
};

// ============================================================================
// Queue type aliases
// ============================================================================

pub const InQueue = BoundedQueue(WorkItem, 256);
pub const OutQueue = BoundedQueue(OutMessage, 1024);

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
