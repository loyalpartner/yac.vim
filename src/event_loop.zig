const std = @import("std");
const json_utils = @import("json_utils.zig");
const lsp_registry_mod = @import("lsp/registry.zig");
const picker_mod = @import("picker.zig");
const log = @import("log.zig");
const clients_mod = @import("clients.zig");
const vim_expr_tracker_mod = @import("vim_expr_tracker.zig");
const lsp_mod = @import("lsp/lsp.zig");
const treesitter_mod = @import("treesitter/treesitter.zig");
const queue_mod = @import("queue.zig");
const dap_bridge_mod = @import("dap_bridge.zig");
const lsp_bridge_mod = @import("lsp_bridge.zig");
const msg_mod = @import("message_dispatcher.zig");

const Allocator = std.mem.Allocator;

const ClientId = clients_mod.ClientId;

const IDLE_TIMEOUT_NS: i128 = 60 * std.time.ns_per_s;

/// Maximum bytes buffered per client before the connection is dropped.
/// Guards against a malicious or buggy client causing OOM by sending
/// data without newlines (the message framing delimiter).
pub const MAX_CLIENT_BUF: usize = 4 * 1024 * 1024; // 4 MB

/// Returns true if adding `incoming` bytes to a buffer of `current_len`
/// would exceed MAX_CLIENT_BUF.
pub fn clientBufWouldOverflow(current_len: usize, incoming: usize) bool {
    return current_len + incoming > MAX_CLIENT_BUF;
}

pub const EventLoop = struct {
    allocator: Allocator,
    lsp: lsp_mod.Lsp,
    listener: std.net.Server,
    clients: clients_mod.Clients,
    /// In-flight daemon→Vim expr request tracking.
    expr_tracker: vim_expr_tracker_mod.VimExprTracker,
    /// Timestamp (nanos) when daemon should exit if no clients; null = has clients
    idle_deadline: ?i128,
    /// Picker state (active while picker is open)
    picker: picker_mod.Picker,
    /// Tree-sitter state
    ts: treesitter_mod.TreeSitter,
    /// DAP bridge (owns DAP session lifecycle).
    dap: dap_bridge_mod.DapBridge,
    /// LSP bridge (owns pending request tracking and LSP message processing).
    lsp_bridge: lsp_bridge_mod.LspBridge,
    /// Message dispatcher (JSON parsing, RPC routing, response strategy).
    msg: msg_mod.MessageDispatcher,
    /// Set by "exit" handler to trigger clean shutdown.
    shutdown_requested: bool = false,
    /// Protects all shared mutable state when accessed from worker threads.
    state_lock: std.Thread.Mutex = .{},
    /// Work queue for general (non-TS) requests: reader thread → worker threads.
    in_general: queue_mod.RecvChannel = .{},
    /// Work queue for tree-sitter requests: reader thread → TS thread.
    in_ts: queue_mod.RecvChannel = .{},
    /// Outgoing message queue: worker/main threads → writer thread.
    out_queue: queue_mod.SendChannel = .{},
    /// Reusable poll set (lives for the entire EventLoop lifetime).
    poll: PollSet = .{},

    pub fn init(allocator: Allocator, listener: std.net.Server) EventLoop {
        return .{
            .allocator = allocator,
            .lsp = lsp_mod.Lsp.init(allocator),
            .listener = listener,
            .clients = clients_mod.Clients.init(allocator),
            .expr_tracker = vim_expr_tracker_mod.VimExprTracker.init(allocator),
            .idle_deadline = std.time.nanoTimestamp(),
            .picker = picker_mod.Picker.init(allocator),
            .ts = treesitter_mod.TreeSitter.init(allocator),
            // Bridges and dispatcher hold pointers to other EventLoop fields,
            // so they must be initialized AFTER the struct reaches its final
            // memory location. See initBridges().
            .dap = undefined,
            .lsp_bridge = undefined,
            .msg = undefined,
        };
    }

    /// Initialize bridges and dispatcher that hold pointers to other EventLoop fields.
    /// Must be called once, after the EventLoop is at its final memory location
    /// (i.e. after `var event_loop = EventLoop.init(...)` returns).
    pub fn initBridges(self: *EventLoop) void {
        self.dap = dap_bridge_mod.DapBridge.init(self.allocator, &self.out_queue, &self.clients);
        self.lsp_bridge = lsp_bridge_mod.LspBridge.init(self.allocator, &self.lsp, &self.in_general, &self.in_ts, &self.out_queue, &self.clients, &self.expr_tracker);
        self.msg = .{
            .allocator = self.allocator,
            .lsp = &self.lsp,
            .lsp_bridge = &self.lsp_bridge,
            .picker = &self.picker,
            .expr_tracker = &self.expr_tracker,
            .ts = &self.ts,
            .dap = &self.dap,
            .clients = &self.clients,
            .out_queue = &self.out_queue,
            .shutdown_requested = &self.shutdown_requested,
        };
    }

    pub fn deinit(self: *EventLoop) void {
        self.dap.deinit();
        self.lsp_bridge.deinit();
        self.poll.deinit(self.allocator);
        self.lsp.deinit();
        self.expr_tracker.deinit();
        self.clients.deinit();
        self.picker.deinit();
        self.ts.deinit();
        self.listener.deinit();
    }

    // ====================================================================
    // Poll infrastructure — PollSet + FdKind (tagged union dispatch)
    // ====================================================================

    /// Identifies the source of each polled fd for dispatch.
    pub const FdKind = union(enum) {
        listener,
        client: ClientId,
        lsp_stdout: []const u8, // client_key
        lsp_stderr: []const u8, // client_key
        dap_stdout,
        picker_stdout,
    };

    /// Paired fd + tag arrays, reused across poll iterations (P2: zero steady-state alloc).
    const PollSet = struct {
        fds: std.ArrayListUnmanaged(std.posix.pollfd) = .{},
        tags: std.ArrayListUnmanaged(FdKind) = .{},

        fn add(self: *PollSet, alloc: Allocator, fd: std.posix.fd_t, tag: FdKind) !void {
            try self.fds.append(alloc, .{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 });
            try self.tags.append(alloc, tag);
        }

        fn clear(self: *PollSet) void {
            self.fds.clearRetainingCapacity();
            self.tags.clearRetainingCapacity();
        }

        fn deinit(self: *PollSet, alloc: Allocator) void {
            self.fds.deinit(alloc);
            self.tags.deinit(alloc);
        }
    };

    // ====================================================================
    // Poll helpers
    // ====================================================================

    /// Rebuild the poll fd set from current state. Must be called under state_lock.
    fn collectFds(self: *EventLoop) !void {
        self.poll.clear();

        // Listener socket
        try self.poll.add(self.allocator, self.listener.stream.handle, .listener);

        // Vim client connections
        var cit = self.clients.iterator();
        while (cit.next()) |entry| {
            try self.poll.add(self.allocator, entry.value_ptr.*.stream.handle, .{ .client = entry.key_ptr.* });
        }

        // LSP server stdout + stderr
        var lsp_it = self.lsp.registry.clients.iterator();
        while (lsp_it.next()) |entry| {
            const lsp_client = entry.value_ptr.*;
            try self.poll.add(self.allocator, lsp_client.stdoutFd(), .{ .lsp_stdout = entry.key_ptr.* });
            if (lsp_client.stderrFd()) |fd|
                try self.poll.add(self.allocator, fd, .{ .lsp_stderr = entry.key_ptr.* });
        }
        if (self.lsp.registry.copilot_client) |c| {
            try self.poll.add(self.allocator, c.stdoutFd(), .{ .lsp_stdout = lsp_registry_mod.LspRegistry.copilot_key });
            if (c.stderrFd()) |fd|
                try self.poll.add(self.allocator, fd, .{ .lsp_stderr = lsp_registry_mod.LspRegistry.copilot_key });
        }

        // DAP adapter stdout (stderr is .Ignore)
        if (self.dap.stdoutFd()) |fd|
            try self.poll.add(self.allocator, fd, .dap_stdout);

        // Picker child stdout
        if (self.picker.getStdoutFd()) |fd|
            try self.poll.add(self.allocator, fd, .picker_stdout);
    }

    fn pollTimeout(self: *EventLoop) i32 {
        const deadline = self.idle_deadline orelse return 100;
        const remaining_ns = deadline - std.time.nanoTimestamp();
        if (remaining_ns <= 0) return 0;
        return @intCast(@min(@divTrunc(remaining_ns, std.time.ns_per_ms), 100));
    }

    fn shouldExitIdle(self: *EventLoop) bool {
        if (self.shutdown_requested) {
            log.info("Shutdown requested, exiting", .{});
            return true;
        }
        const deadline = self.idle_deadline orelse return false;
        if (std.time.nanoTimestamp() >= deadline and self.clients.count() == 0) {
            log.info("Idle timeout reached with no clients, shutting down", .{});
            return true;
        }
        return false;
    }

    // ====================================================================
    // Dispatch — iterate poll results by tag, no index arithmetic
    // ====================================================================

    fn dispatch(self: *EventLoop, buf: []u8) void {
        const POLL = std.posix.POLL;
        for (self.poll.fds.items, self.poll.tags.items) |pfd, tag| {
            if (pfd.revents == 0) continue;
            switch (tag) {
                .listener => {
                    if (pfd.revents & POLL.IN != 0) self.acceptClient();
                    if (pfd.revents & POLL.ERR != 0) {
                        log.err("Listener socket error, shutting down", .{});
                        self.shutdown_requested = true;
                    }
                },
                .client => |cid| {
                    if (pfd.revents & POLL.IN != 0) self.readClient(cid, buf);
                    if (pfd.revents & (POLL.HUP | POLL.ERR) != 0) {
                        if (self.clients.get(cid) != null) {
                            log.info("client {d} HUP/ERR, disconnecting", .{cid});
                            self.removeClient(cid);
                        }
                    }
                },
                .lsp_stdout => |key| {
                    if (pfd.revents & POLL.IN != 0) {
                        if (tryRead(pfd.fd, buf)) |n| {
                            self.lsp_bridge.feedOutput(key, buf[0..n]);
                        } else {
                            self.lsp_bridge.handleDeath(key);
                            continue;
                        }
                    }
                    if (pfd.revents & (POLL.HUP | POLL.ERR) != 0)
                        self.lsp_bridge.handleDeath(key);
                },
                .lsp_stderr => |key| {
                    if (pfd.revents & POLL.IN != 0)
                        self.drainStderr(key, buf);
                },
                .dap_stdout => {
                    if (pfd.revents & POLL.IN != 0) {
                        if (tryRead(pfd.fd, buf)) |n| {
                            self.dap.feedOutput(buf[0..n]);
                        } else {
                            self.dap.handleDisconnect();
                            continue;
                        }
                    }
                    if (pfd.revents & (POLL.HUP | POLL.ERR) != 0) {
                        // Drain remaining data before disconnect
                        while (tryRead(pfd.fd, buf)) |n|
                            self.dap.feedOutput(buf[0..n]);
                        self.dap.handleDisconnect();
                    }
                },
                .picker_stdout => {
                    if (pfd.revents & (POLL.IN | POLL.HUP) != 0)
                        self.picker.pollScan();
                },
            }
        }
    }

    // ====================================================================
    // Per-fd read helpers
    // ====================================================================

    fn tryRead(fd: std.posix.fd_t, buf: []u8) ?usize {
        const n = std.posix.read(fd, buf) catch return null;
        return if (n == 0) null else n;
    }

    /// Read from a Vim client socket and route complete lines to work queues.
    fn readClient(self: *EventLoop, cid: ClientId, buf: []u8) void {
        const client = self.clients.get(cid) orelse return;
        const n = std.posix.read(client.stream.handle, buf) catch |e| {
            log.err("client {d} read failed: {any}", .{ cid, e });
            self.removeClient(cid);
            return;
        };
        if (n == 0) {
            log.info("client {d} EOF, disconnecting", .{cid});
            self.removeClient(cid);
            return;
        }
        if (clientBufWouldOverflow(client.read_buf.items.len, n)) {
            log.err("client {d} read_buf overflow ({d} bytes), disconnecting", .{ cid, client.read_buf.items.len + n });
            self.removeClient(cid);
            return;
        }
        client.read_buf.appendSlice(self.allocator, buf[0..n]) catch |e| {
            log.err("client {d} buf append failed: {any}", .{ cid, e });
            return;
        };
        self.processClientInput(cid);
    }

    /// Drain LSP stderr to prevent pipe buffer from filling.
    /// Stores the last chunk for crash diagnostics.
    fn drainStderr(self: *EventLoop, key: []const u8, buf: []u8) void {
        const client = self.lsp.registry.getClient(key) orelse return;
        const stderr_fd = client.stderrFd() orelse return;
        const n = std.posix.read(stderr_fd, buf) catch return;
        if (n > 0) client.appendStderr(buf[0..n]);
    }

    // ====================================================================
    // Thread loops
    // ====================================================================

    /// Generic queue consumer: pops Envelopes, acquires state_lock, dispatches each one.
    /// Used by both general worker threads and the TS thread.
    fn queueLoop(self: *EventLoop, queue: *queue_mod.RecvChannel) void {
        while (queue.pop()) |item| {
            defer item.deinit(self.allocator);
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            self.state_lock.lock();
            defer self.state_lock.unlock();
            self.msg.handleWorkItem(item, arena.allocator());
        }
    }

    /// Writer thread: drains the out_queue and writes messages to Vim clients.
    fn writerLoop(self: *EventLoop) void {
        while (self.out_queue.pop()) |msg| {
            defer msg.deinit(self.allocator);
            msg.stream.writeAll(msg.bytes) catch |e| {
                log.err("Writer: socket write failed: {any}", .{e});
            };
        }
    }

    /// Main event loop using poll().
    /// Spawns worker, TS, and writer threads; runs the poll loop; then joins all threads.
    pub fn run(self: *EventLoop) !void {
        var buf: [65536]u8 = undefined; // shared read buffer (sized for DAP messages)

        log.info("Entering event loop (daemon mode)", .{});
        self.idle_deadline = std.time.nanoTimestamp() + IDLE_TIMEOUT_NS;

        // Spawn background threads.
        const num_workers = 4;
        var worker_threads: [num_workers]std.Thread = undefined;
        for (&worker_threads) |*t| {
            t.* = try std.Thread.spawn(.{}, queueLoop, .{ self, &self.in_general });
        }
        const ts_thread = try std.Thread.spawn(.{}, queueLoop, .{ self, &self.in_ts });
        const writer_thread = try std.Thread.spawn(.{}, writerLoop, .{self});

        defer {
            self.in_general.close();
            self.in_ts.close();
            for (worker_threads) |t| t.join();
            ts_thread.join();
            self.out_queue.close();
            writer_thread.join();
        }

        while (true) {
            self.state_lock.lock();
            self.collectFds() catch |e| {
                self.state_lock.unlock();
                log.err("collectFds failed: {any}", .{e});
                continue;
            };
            const timeout = self.pollTimeout();
            self.state_lock.unlock();

            // poll() without the lock so workers can run concurrently.
            const ready = std.posix.poll(self.poll.fds.items, timeout) catch |e| {
                log.err("poll failed: {any}", .{e});
                continue;
            };

            if (ready == 0) {
                self.state_lock.lock();
                const should_exit = self.shouldExitIdle();
                self.state_lock.unlock();
                if (should_exit) break;
                continue;
            }

            self.state_lock.lock();
            self.dispatch(&buf);
            const should_exit = self.shutdown_requested;
            self.state_lock.unlock();
            if (should_exit) break;
        }
    }

    /// Accept a new Vim client connection.
    fn acceptClient(self: *EventLoop) void {
        const cid = self.clients.accept(&self.listener) orelse return;

        // Clear idle deadline — we have a client now
        self.idle_deadline = null;
        log.info("Client {d} connected (total: {d})", .{ cid, self.clients.count() });
    }

    /// Remove a disconnected client and clean up.
    fn removeClient(self: *EventLoop, cid: ClientId) void {
        // Delegate LSP pending + deferred cleanup to bridge
        self.lsp_bridge.removeForClient(cid);

        self.clients.remove(cid);

        log.info("Client {d} removed (remaining: {d})", .{ cid, self.clients.count() });

        // Set idle deadline if no clients remain
        if (self.clients.count() == 0) {
            self.idle_deadline = std.time.nanoTimestamp() + IDLE_TIMEOUT_NS;
            log.info("No clients, will exit in 60s", .{});
        }
    }

    /// Read completed lines from a client's buffer and route them to the work queues.
    fn processClientInput(self: *EventLoop, cid: ClientId) void {
        while (true) {
            const client = self.clients.get(cid) orelse break;
            const newline_pos = std.mem.indexOf(u8, client.read_buf.items, "\n") orelse break;

            const line = client.read_buf.items[0..newline_pos];
            if (line.len > 0) {
                // GPA-allocate a copy of the line; ownership passes to Envelope.
                const raw_line = self.allocator.dupe(u8, line) catch |e| {
                    log.err("OOM routing work item: {any}", .{e});
                    // Skip this line, continue processing remaining buffer.
                    const c2 = self.clients.get(cid) orelse break;
                    const rem2 = c2.read_buf.items.len - newline_pos - 1;
                    if (rem2 > 0) std.mem.copyForwards(u8, c2.read_buf.items[0..rem2], c2.read_buf.items[newline_pos + 1 ..]);
                    c2.read_buf.shrinkRetainingCapacity(rem2);
                    continue;
                };

                // DAP step/continue: dispatch inline (skip work queue round trip)
                if (queue_mod.isDapActionMethod(line)) {
                    defer self.allocator.free(raw_line);
                    var arena = std.heap.ArenaAllocator.init(self.allocator);
                    defer arena.deinit();
                    self.msg.handleWorkItem(.{
                        .client_id = cid,
                        .client_stream = client.stream,
                        .raw_line = raw_line,
                    }, arena.allocator());
                } else {
                    const item = queue_mod.Envelope{
                        .client_id = cid,
                        .client_stream = client.stream,
                        .raw_line = raw_line,
                    };
                    const routed = if (queue_mod.isTsMethod(line))
                        self.in_ts.push(item)
                    else
                        self.in_general.push(item);

                    if (!routed) {
                        item.deinit(self.allocator);
                        log.warn("Work queue full, dropping line from client {d}", .{cid});
                    }
                }
            }

            // Remove processed line from buffer.
            const c = self.clients.get(cid) orelse break;
            const remaining = c.read_buf.items.len - newline_pos - 1;
            if (remaining > 0) {
                std.mem.copyForwards(u8, c.read_buf.items[0..remaining], c.read_buf.items[newline_pos + 1 ..]);
            }
            c.read_buf.shrinkRetainingCapacity(remaining);
        }
    }
};

// ============================================================================
// Tests
// ============================================================================

test "MAX_CLIENT_BUF is 4MB" {
    try std.testing.expectEqual(@as(usize, 4 * 1024 * 1024), MAX_CLIENT_BUF);
}

test "clientBufWouldOverflow: returns true when adding data exceeds limit" {
    // Simulate a buffer already at the limit
    try std.testing.expect(clientBufWouldOverflow(MAX_CLIENT_BUF, 1));
    // One byte under the limit is fine
    try std.testing.expect(!clientBufWouldOverflow(MAX_CLIENT_BUF - 1, 1));
    // Exactly at limit is an overflow
    try std.testing.expect(clientBufWouldOverflow(MAX_CLIENT_BUF - 1, 2));
    // Empty buffer with zero bytes is fine
    try std.testing.expect(!clientBufWouldOverflow(0, 0));
    // Empty buffer with max bytes is fine (at boundary)
    try std.testing.expect(!clientBufWouldOverflow(0, MAX_CLIENT_BUF));
    // Empty buffer with max+1 bytes overflows
    try std.testing.expect(clientBufWouldOverflow(0, MAX_CLIENT_BUF + 1));
}
