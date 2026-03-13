const std = @import("std");
const json_utils = @import("json_utils.zig");
const vim = @import("vim_protocol.zig");
const lsp_registry_mod = @import("lsp/registry.zig");
const handlers_mod = @import("handlers.zig");
const picker_mod = @import("picker.zig");
const log = @import("log.zig");
const lsp_transform = @import("lsp/transform.zig");
const clients_mod = @import("clients.zig");
const requests_mod = @import("requests.zig");
const lsp_mod = @import("lsp/lsp.zig");
const progress_mod = @import("progress.zig");
const treesitter_mod = @import("treesitter/treesitter.zig");
const queue_mod = @import("queue.zig");
const dap_client_mod = @import("dap/client.zig");
const dap_session_mod = @import("dap/session.zig");
const dap_protocol = @import("dap/protocol.zig");

const Allocator = std.mem.Allocator;
const Value = json_utils.Value;
const ObjectMap = json_utils.ObjectMap;

const ClientId = clients_mod.ClientId;
const PendingVimExpr = requests_mod.PendingVimExpr;

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
    /// Request tracking for in-flight LSP and Vim expr requests
    requests: requests_mod.Requests,
    /// Progress title tracking (from $/progress begin, used for report events)
    progress: progress_mod.Progress,
    /// Timestamp (nanos) when daemon should exit if no clients; null = has clients
    idle_deadline: ?i128,
    /// Picker state (active while picker is open)
    picker: picker_mod.Picker,
    /// Tree-sitter state
    ts: treesitter_mod.TreeSitter,
    /// Active DAP debug session (single session at a time).
    dap_session: ?*dap_session_mod.DapSession = null,
    /// Set by "exit" handler to trigger clean shutdown.
    shutdown_requested: bool = false,
    /// Protects all shared mutable state when accessed from worker threads.
    state_lock: std.Thread.Mutex = .{},
    /// Work queue for general (non-TS) requests: reader thread → worker threads.
    in_general: queue_mod.InQueue = .{},
    /// Work queue for tree-sitter requests: reader thread → TS thread.
    in_ts: queue_mod.InQueue = .{},
    /// Outgoing message queue: worker/main threads → writer thread.
    out_queue: queue_mod.OutQueue = .{},

    const DeferredRequest = lsp_mod.Lsp.DeferredRequest;

    pub fn init(allocator: Allocator, listener: std.net.Server) EventLoop {
        const ts_state = treesitter_mod.TreeSitter.init(allocator);
        return .{
            .allocator = allocator,
            .lsp = lsp_mod.Lsp.init(allocator),
            .listener = listener,
            .clients = clients_mod.Clients.init(allocator),
            .requests = requests_mod.Requests.init(allocator),
            .progress = progress_mod.Progress.init(allocator),
            .idle_deadline = std.time.nanoTimestamp(),
            .picker = picker_mod.Picker.init(allocator),
            .ts = ts_state,
        };
    }

    pub fn deinit(self: *EventLoop) void {
        if (self.dap_session) |s| {
            s.client.deinit();
            s.deinit();
            self.allocator.destroy(s);
        }
        self.lsp.deinit();
        self.requests.deinit();
        self.clients.deinit();
        self.progress.deinit();
        self.picker.deinit();
        self.ts.deinit();
        self.listener.deinit();
    }

    const PollSetup = struct {
        client_count: usize,
        picker_fd_index: ?usize,
        dap_fd_index: ?usize,
    };

    fn buildPollFds(
        self: *EventLoop,
        poll_fds: *std.ArrayList(std.posix.pollfd),
        poll_client_keys: *std.ArrayList([]const u8),
        client_id_order: *std.ArrayList(ClientId),
    ) !PollSetup {
        // fd[0] = listener (accept new Vim connections)
        try poll_fds.append(self.allocator, .{
            .fd = self.listener.stream.handle,
            .events = std.posix.POLL.IN,
            .revents = 0,
        });

        // fd[1..N] = client stream fds
        var cit = self.clients.iterator();
        while (cit.next()) |entry| {
            try poll_fds.append(self.allocator, .{
                .fd = entry.value_ptr.*.stream.handle,
                .events = std.posix.POLL.IN,
                .revents = 0,
            });
            try client_id_order.append(self.allocator, entry.key_ptr.*);
        }

        const client_count = client_id_order.items.len;

        // fd[N+1..N+M] = LSP server stdouts
        try self.lsp.registry.collectFds(poll_fds, poll_client_keys);

        // fd[N+M+1] = DAP adapter stdout (if active)
        const dap_fd_index: ?usize = if (self.dap_session) |session| idx: {
            const idx = poll_fds.items.len;
            try poll_fds.append(self.allocator, .{
                .fd = session.client.stdoutFd(),
                .events = std.posix.POLL.IN,
                .revents = 0,
            });
            break :idx idx;
        } else null;

        // fd[N+M+2] = picker fd/find stdout (if active)
        const picker_fd_index: ?usize = if (self.picker.getStdoutFd()) |fd| idx: {
            const idx = poll_fds.items.len;
            try poll_fds.append(self.allocator, .{
                .fd = fd,
                .events = std.posix.POLL.IN,
                .revents = 0,
            });
            break :idx idx;
        } else null;

        return .{ .client_count = client_count, .picker_fd_index = picker_fd_index, .dap_fd_index = dap_fd_index };
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

    fn handleListener(self: *EventLoop, poll_fds: []std.posix.pollfd) void {
        if (poll_fds.len == 0) return;
        if (poll_fds[0].revents & std.posix.POLL.IN != 0) {
            self.acceptClient();
        }
    }

    fn handleClientFds(
        self: *EventLoop,
        poll_fds: []std.posix.pollfd,
        client_count: usize,
        client_id_order: []ClientId,
        buf: []u8,
    ) void {
        for (poll_fds[1 .. 1 + client_count], 0..) |pfd, i| {
            const cid = client_id_order[i];

            if (pfd.revents & std.posix.POLL.IN != 0) {
                const client = self.clients.get(cid) orelse continue;
                const n = std.posix.read(client.stream.handle, buf) catch |e| {
                    log.err("client {d} read failed: {any}", .{ cid, e });
                    self.removeClient(cid);
                    continue;
                };
                if (n == 0) {
                    log.info("client {d} EOF, disconnecting", .{cid});
                    self.removeClient(cid);
                    continue;
                }
                // Guard against OOM: disconnect clients that send unbounded data
                // without newline framing (e.g. malicious or buggy clients).
                if (clientBufWouldOverflow(client.read_buf.items.len, n)) {
                    log.err("client {d} read_buf overflow ({d} bytes), disconnecting", .{ cid, client.read_buf.items.len + n });
                    self.removeClient(cid);
                    continue;
                }
                client.read_buf.appendSlice(self.allocator, buf[0..n]) catch |e| {
                    log.err("client {d} buf append failed: {any}", .{ cid, e });
                    continue;
                };
                self.processClientInput(cid);
            }

            if (pfd.revents & (std.posix.POLL.HUP | std.posix.POLL.ERR) != 0) {
                log.info("client {d} HUP/ERR, disconnecting", .{cid});
                self.removeClient(cid);
            }
        }
    }

    fn handleLspFds(
        self: *EventLoop,
        poll_fds: []std.posix.pollfd,
        client_count: usize,
        poll_client_keys: []const []const u8,
    ) void {
        const lsp_end = 1 + client_count + poll_client_keys.len;
        for (poll_fds[1 + client_count .. lsp_end], 0..) |pfd, i| {
            if (pfd.revents & std.posix.POLL.IN != 0) {
                const client_key = poll_client_keys[i];
                self.processLspOutput(client_key);
            }
            if (pfd.revents & (std.posix.POLL.HUP | std.posix.POLL.ERR) != 0) {
                const dead_key = poll_client_keys[i];
                self.handleLspDeath(dead_key);
            }
        }
    }

    fn handleDapFd(self: *EventLoop, poll_fds: []std.posix.pollfd, dap_fd_index: ?usize) void {
        const dfi = dap_fd_index orelse return;
        const revents = poll_fds[dfi].revents;

        // Always process available data first, even when HUP is also set.
        // The adapter may send initialize response + initialized event then close.
        if (revents & std.posix.POLL.IN != 0) {
            self.processDapOutput();
        }

        if (revents & (std.posix.POLL.HUP | std.posix.POLL.ERR) != 0) {
            // Drain any remaining data before cleanup
            if (self.dap_session) |session| {
                while (true) {
                    var arena = std.heap.ArenaAllocator.init(self.allocator);
                    defer arena.deinit();
                    const alloc = arena.allocator();

                    var msgs = session.client.readMessages(alloc) catch break;
                    defer msgs.deinit(self.allocator);
                    if (msgs.items.len == 0) break;

                    for (msgs.items) |msg| {
                        switch (msg) {
                            .response => |r| self.handleDapResponse(alloc, session, r),
                            .event => |e| self.handleDapEvent(alloc, session, e),
                        }
                        if (self.dap_session == null) break;
                    }
                    if (self.dap_session == null) break;
                }
            }
            if (self.dap_session != null) {
                log.info("DAP adapter disconnected (HUP/ERR)", .{});
                self.cleanupDapSession();
            }
        }
    }

    fn handlePickerFd(self: *EventLoop, poll_fds: []std.posix.pollfd, picker_fd_index: ?usize) void {
        if (picker_fd_index) |pfi| {
            if (poll_fds[pfi].revents & (std.posix.POLL.IN | std.posix.POLL.HUP) != 0) {
                self.picker.pollScan();
            }
        }
    }

    // ====================================================================
    // Thread loops
    // ====================================================================

    /// Generic queue consumer: pops WorkItems, acquires state_lock, dispatches each one.
    /// Used by both general worker threads and the TS thread.
    fn queueLoop(self: *EventLoop, queue: *queue_mod.InQueue) void {
        while (queue.pop()) |item| {
            defer item.deinit(self.allocator);
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            self.state_lock.lock();
            defer self.state_lock.unlock();
            self.handleWorkItem(item, arena.allocator());
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
        var buf: [8192]u8 = undefined;

        log.info("Entering event loop (daemon mode)", .{});
        // Set idle deadline since we start with no clients
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
            // Drain work queues first, then drain the out_queue.
            self.in_general.close();
            self.in_ts.close();
            for (worker_threads) |t| t.join();
            ts_thread.join();
            self.out_queue.close();
            writer_thread.join();
        }

        while (true) {
            // Build poll fd list under lock (accesses clients, lsp.registry, picker).
            var poll_fds: std.ArrayList(std.posix.pollfd) = .{};
            defer poll_fds.deinit(self.allocator);
            var poll_client_keys: std.ArrayList([]const u8) = .{};
            defer poll_client_keys.deinit(self.allocator);
            var client_id_order: std.ArrayList(ClientId) = .{};
            defer client_id_order.deinit(self.allocator);

            self.state_lock.lock();
            const poll_setup = self.buildPollFds(&poll_fds, &poll_client_keys, &client_id_order) catch |e| {
                self.state_lock.unlock();
                log.err("buildPollFds failed: {any}", .{e});
                continue;
            };
            const poll_timeout = self.pollTimeout();
            self.state_lock.unlock();

            // poll() without the lock so workers can run concurrently.
            const ready = std.posix.poll(poll_fds.items, poll_timeout) catch |e| {
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

            // Process ready fds under lock.
            self.state_lock.lock();
            self.handleListener(poll_fds.items);
            self.handleClientFds(poll_fds.items, poll_setup.client_count, client_id_order.items, buf[0..]);
            self.handleLspFds(poll_fds.items, poll_setup.client_count, poll_client_keys.items);
            self.handleDapFd(poll_fds.items, poll_setup.dap_fd_index);
            self.handlePickerFd(poll_fds.items, poll_setup.picker_fd_index);
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
        // Remove pending LSP requests for this client
        var to_remove: std.ArrayList(u32) = .{};
        defer to_remove.deinit(self.allocator);

        var pit = self.requests.lspIterator();
        while (pit.next()) |entry| {
            if (entry.value_ptr.client_id == cid) {
                to_remove.append(self.allocator, entry.key_ptr.*) catch {};
            }
        }
        for (to_remove.items) |req_id| {
            if (self.requests.removeLsp(req_id)) |pending| {
                pending.deinit(self.allocator);
            }
        }

        // Remove deferred requests for this client
        self.lsp.removeDeferredForClient(cid);

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
                // GPA-allocate a copy of the line; ownership passes to WorkItem.
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
                    const alloc = arena.allocator();
                    self.handleWorkItem(.{
                        .client_id = cid,
                        .client_stream = client.stream,
                        .raw_line = raw_line,
                    }, alloc);
                } else {
                    const item = queue_mod.WorkItem{
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

    /// Handle a work item from the queue (called by worker threads under state_lock).
    fn handleWorkItem(self: *EventLoop, item: queue_mod.WorkItem, alloc: Allocator) void {
        const trimmed = std.mem.trim(u8, item.raw_line, &std.ascii.whitespace);
        if (trimmed.len == 0) return;

        // Parse JSON
        const parsed = json_utils.parse(alloc, trimmed) catch |e| {
            log.err("JSON parse error: {any}", .{e});
            return;
        };

        // Must be an array (Vim channel protocol)
        const arr = switch (parsed.value) {
            .array => |a| a.items,
            else => {
                log.err("Expected JSON array from Vim", .{});
                return;
            },
        };

        // Intercept responses to our pending expr requests.
        // Vim sends [positive_id, result] which parseJsonRpc would misinterpret.
        if (arr.len == 2 and arr[0] == .integer) {
            if (self.requests.takeExpr(arr[0].integer)) |pending| {
                self.handleVimExprResponse(alloc, pending, arr[1]);
                return;
            }
        }

        // Parse as JSON-RPC
        const msg = vim.parseJsonRpc(arr) catch |e| {
            log.err("Protocol parse error: {any}", .{e});
            return;
        };

        switch (msg) {
            .request => |r| {
                log.debug("Vim[{d}] request [{d}]: {s}", .{ item.client_id, r.id, r.method });
                self.handleVimRequest(item.client_id, alloc, r.id, r.method, r.params, trimmed, item.client_stream);
            },
            .notification => |n| {
                log.debug("Vim[{d}] notification: {s}", .{ item.client_id, n.method });
                self.handleVimRequest(item.client_id, alloc, null, n.method, n.params, trimmed, item.client_stream);
            },
            .response => {
                // Responses to Vim "call" commands (expr responses intercepted above)
            },
        }
    }

    /// Handle a Vim request or notification.
    /// client_stream is captured from the WorkItem at routing time.
    fn handleVimRequest(self: *EventLoop, cid: ClientId, alloc: Allocator, vim_id: ?u64, method: []const u8, params: Value, raw_line: []const u8, client_stream: std.net.Stream) void {
        // Defer query methods while the relevant LSP server is indexing
        if (vim_id != null and lsp_mod.isQueryMethod(method)) {
            const lang = blk: {
                const obj = switch (params) {
                    .object => |o| o,
                    else => break :blk null,
                };
                const file = json_utils.getString(obj, "file") orelse break :blk null;
                break :blk lsp_registry_mod.LspRegistry.detectLanguage(lsp_registry_mod.extractRealPath(file));
            };
            if (lang) |language| {
                if (self.lsp.isLanguageIndexing(language)) {
                    if (self.lsp.enqueueDeferred(cid, raw_line)) {
                        log.info("Deferred {s} request (LSP indexing in progress)", .{method});
                        if (lsp_transform.formatToastCmd(alloc, "[yac] LSP indexing, request queued...", null)) |cmd|
                            self.sendVimExTo(cid, alloc, cmd);
                    }
                    return;
                }
            }
        }

        var ctx = handlers_mod.HandlerContext{
            .allocator = alloc,
            .gpa_allocator = self.allocator,
            .registry = &self.lsp.registry,
            .lsp = &self.lsp,
            .client_stream = client_stream,
            .client_id = cid,
            .ts = &self.ts,
            .dap_session = &self.dap_session,
            .out_queue = &self.out_queue,
            .shutdown_flag = &self.shutdown_requested,
        };

        const result = handlers_mod.dispatch(&ctx, method, params) catch |e| {
            log.err("Handler error for {s}: {any}", .{ method, e });
            self.sendVimErrorTo(cid, alloc, vim_id, "Handler error");
            return;
        };

        switch (result) {
            .data => |data| {
                switch (self.picker.processAction(alloc, data)) {
                    .none => self.sendVimResponseTo(cid, alloc, vim_id, data),
                    .respond_null => self.sendVimResponseTo(cid, alloc, vim_id, .null),
                    .respond => |v| self.sendVimResponseTo(cid, alloc, vim_id, v),
                    .query_buffers => self.sendVimExprTo(cid, alloc, vim_id, "map(getbufinfo({'buflisted':1}), {_, b -> b.name})", .picker_buffers),
                }
            },
            .empty => {
                if (vim_id != null) {
                    self.sendVimResponseTo(cid, alloc, vim_id, .null);
                }
            },
            .initializing => {
                if (vim_id != null) {
                    if (self.lsp.enqueueDeferred(cid, raw_line)) {
                        log.info("Deferred {s} request (LSP initializing)", .{method});
                        if (lsp_transform.formatToastCmd(alloc, "[yac] LSP initializing, request queued...", null)) |cmd|
                            self.sendVimExTo(cid, alloc, cmd);
                    } else {
                        self.sendVimResponseTo(cid, alloc, vim_id, .null);
                    }
                }
            },
            .pending_lsp => |pending| {
                self.trackPendingRequest(pending.lsp_request_id, cid, vim_id, method, params, pending.client_key);
            },
            .data_with_subscribe => |ds| {
                self.clients.subscribeClient(cid, ds.workspace_uri);
                self.sendVimResponseTo(cid, alloc, vim_id, ds.data);
            },
        }

        // After did_save: notify other clients in the same workspace to reload
        if (std.mem.eql(u8, method, "did_save")) {
            self.broadcastChecktimeToOthers(cid, alloc, params);
        }
    }

    /// Track a pending LSP request so the response can be routed back to the correct Vim client.
    fn trackPendingRequest(self: *EventLoop, lsp_request_id: u32, cid: ClientId, vim_id: ?u64, method: []const u8, params: Value, client_key: ?[]const u8) void {
        const params_obj: ?ObjectMap = switch (params) {
            .object => |o| o,
            else => null,
        };
        const file = if (params_obj) |obj| json_utils.getString(obj, "file") else null;
        const ssh_host = if (file) |f| lsp_registry_mod.extractSshHost(f) else null;

        // Cancel older in-flight requests of the same method+client (e.g. completion)
        if (client_key) |key| {
            var cancelled = self.requests.cancelByMethodAndClientKey(method, key);
            defer cancelled.deinit();
            if (cancelled.lsp_ids.items.len > 0) {
                if (self.lsp.registry.getClient(key)) |lsp_client| {
                    for (cancelled.lsp_ids.items) |old_id| {
                        lsp_client.sendCancelNotification(old_id) catch |e| {
                            log.warn("Failed to send $/cancelRequest for id={d}: {any}", .{ old_id, e });
                        };
                    }
                }
                // Send null responses to Vim for cancelled requests so callbacks don't hang
                for (cancelled.cancelled_vim_info.items) |info| {
                    self.sendVimResponseTo(info.client_id, self.allocator, info.vim_request_id, .null);
                }
                log.debug("Cancelled {d} old {s} request(s)", .{ cancelled.lsp_ids.items.len, method });
            }
        }

        const method_owned = self.allocator.dupe(u8, method) catch |e| {
            log.err("Failed to track pending request: {any}", .{e});
            return;
        };
        const ssh_host_owned = if (ssh_host) |h|
            self.allocator.dupe(u8, h) catch |e| {
                self.allocator.free(method_owned);
                log.err("Failed to track pending request: {any}", .{e});
                return;
            }
        else
            null;
        const file_owned = if (file) |f|
            self.allocator.dupe(u8, f) catch |e| {
                self.allocator.free(method_owned);
                if (ssh_host_owned) |h| self.allocator.free(h);
                log.err("Failed to track pending request: {any}", .{e});
                return;
            }
        else
            null;
        const client_key_owned = if (client_key) |key|
            self.allocator.dupe(u8, key) catch |e| {
                self.allocator.free(method_owned);
                if (ssh_host_owned) |h| self.allocator.free(h);
                if (file_owned) |f| self.allocator.free(f);
                log.err("Failed to track pending request: {any}", .{e});
                return;
            }
        else
            null;

        self.requests.addLsp(lsp_request_id, .{
            .vim_request_id = vim_id,
            .method = method_owned,
            .ssh_host = ssh_host_owned,
            .file = file_owned,
            .client_id = cid,
            .lsp_client_key = client_key_owned,
        }) catch |e| {
            self.allocator.free(method_owned);
            if (ssh_host_owned) |h| self.allocator.free(h);
            if (file_owned) |f| self.allocator.free(f);
            if (client_key_owned) |k| self.allocator.free(k);
            log.err("Failed to track pending request: {any}", .{e});
        };
    }

    /// Process output from an LSP server.
    fn processLspOutput(self: *EventLoop, client_key: []const u8) void {
        const client = self.lsp.registry.getClient(client_key) orelse return;

        var messages = client.readMessages() catch |e| {
            log.err("LSP read error for {s}: {any}", .{ client_key, e });
            return;
        };
        defer {
            for (messages.items) |*msg| msg.deinit();
            messages.deinit(self.allocator);
        }

        for (messages.items) |*msg| {
            switch (msg.kind) {
                .response => |resp| {
                    // Check if this is an initialize response
                    if (self.lsp.registry.getInitRequestId(client_key)) |init_id| {
                        if (resp.id == init_id) {
                            self.lsp.registry.handleInitializeResponse(client_key, resp.result) catch |e| {
                                log.err("Failed to handle init response: {any}", .{e});
                            };
                            if (!self.lsp.isAnyLanguageIndexing()) {
                                self.flushDeferredRequests();
                            }
                            continue;
                        }
                    }

                    // Route to pending Vim request
                    if (self.requests.removeLsp(resp.id)) |pending| {
                        defer pending.deinit(self.allocator);

                        var arena = std.heap.ArenaAllocator.init(self.allocator);
                        defer arena.deinit();

                        if (resp.err) |err_val| {
                            const err_str = json_utils.stringifyAlloc(arena.allocator(), err_val) catch "?";
                            log.err("LSP error for request {d} ({s}): {s}", .{ resp.id, pending.method, err_str });
                            self.sendVimResponseTo(pending.client_id, arena.allocator(), pending.vim_request_id, .null);
                        } else {
                            const transformed = if (std.mem.eql(u8, pending.method, "semantic_tokens")) blk: {
                                // Semantic tokens need the server capabilities to decode the legend
                                const caps_val = if (pending.lsp_client_key) |key|
                                    if (self.lsp.registry.server_capabilities.get(key)) |parsed| parsed.value else null
                                else
                                    null;
                                break :blk lsp_transform.transformSemanticTokensResult(
                                    arena.allocator(),
                                    resp.result,
                                    caps_val,
                                ) catch .null;
                            } else lsp_transform.transformLspResult(
                                arena.allocator(),
                                pending.method,
                                resp.result,
                                pending.ssh_host,
                            );
                            log.debug("LSP response [{d}]: {s} -> Vim[{d}] (null={any})", .{ resp.id, pending.method, pending.client_id, transformed == .null });
                            self.sendVimResponseTo(pending.client_id, arena.allocator(), pending.vim_request_id, transformed);
                        }
                    } else {
                        log.debug("Unmatched LSP response id={d}", .{resp.id});
                    }
                },
                .notification => |notif| {
                    self.handleLspNotification(client_key, notif.method, notif.params);
                },
                .server_request => |req| {
                    self.handleServerRequest(client_key, req.id, req.method, req.params);
                },
            }
        }
    }

    /// Handle a server-to-client request (e.g. workspace/applyEdit).
    fn handleServerRequest(self: *EventLoop, client_key: []const u8, id: i64, method: []const u8, params: Value) void {
        const lsp_client = self.lsp.registry.getClient(client_key) orelse return;

        if (std.mem.eql(u8, method, "workspace/applyEdit")) {
            // Acknowledge the edit request
            var result_obj = ObjectMap.init(self.allocator);
            result_obj.put("applied", json_utils.jsonBool(true)) catch {};
            lsp_client.sendResponse(id, .{ .object = result_obj }) catch |e| {
                log.err("Failed to respond to workspace/applyEdit: {any}", .{e});
            };

            // Forward the edit to subscribed Vim clients
            const workspace_uri = lsp_mod.extractWorkspaceFromKey(client_key);
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const encoded = vim.encodeJsonRpcNotification(arena.allocator(), "applyEdit", params) catch return;
            self.sendToWorkspace(workspace_uri, encoded);
            return;
        }

        // All other server requests: acknowledge with null
        if (!std.mem.eql(u8, method, "window/workDoneProgress/create") and
            !std.mem.eql(u8, method, "client/registerCapability") and
            !std.mem.eql(u8, method, "client/unregisterCapability"))
        {
            log.debug("Unknown server request: {s} (id={d})", .{ method, id });
        }
        lsp_client.sendResponse(id, .null) catch |e| {
            log.err("Failed to respond to {s}: {any}", .{ method, e });
        };
    }

    /// Handle an LSP server that has died (HUP/ERR on its stdout fd).
    // ====================================================================
    // DAP output processing
    // ====================================================================

    fn processDapOutput(self: *EventLoop) void {
        const session = self.dap_session orelse return;

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var messages = session.client.readMessages(alloc) catch |e| {
            log.debug("DAP readMessages error: {any}", .{e});
            if (e == error.AdapterClosed) self.cleanupDapSession();
            return;
        };
        defer messages.deinit(self.allocator);

        for (messages.items) |msg| {
            switch (msg) {
                .response => |r| self.handleDapResponse(alloc, session, r),
                .event => |e| self.handleDapEvent(alloc, session, e),
            }
            if (self.dap_session == null) break;
        }
    }

    fn handleDapResponse(self: *EventLoop, alloc: std.mem.Allocator, session: *dap_session_mod.DapSession, response: dap_protocol.DapResponse) void {
        _ = session.client.pending_requests.fetchRemove(response.request_seq);

        if (std.mem.eql(u8, response.command, "initialize")) {
            session.client.handleInitializeResponse(response);
            // debugpy requires launch BEFORE it sends 'initialized' event.
            // Send launch immediately after initialize response.
            session.client.sendLaunchAfterInit();
            return;
        }

        if (std.mem.eql(u8, response.command, "launch") and response.success) {
            session.client.state = .running;
            session.session_state = .running;
            log.info("DAP: launch succeeded", .{});
        }

        if (!response.success) {
            const err_msg = response.message orelse "unknown error";
            log.err("DAP {s} failed: {s}", .{ response.command, err_msg });
            if (lsp_transform.formatToastCmd(alloc, std.fmt.allocPrint(alloc, "[yac] DAP error: {s}", .{err_msg}) catch return, "ErrorMsg")) |cmd|
                self.sendVimExToAll(alloc, cmd);
            return;
        }

        // Try routing through session chain (auto stopped→stackTrace→scopes→variables)
        const chain_handled = session.handleResponse(alloc, response) catch |e| blk: {
            log.err("DAP chain error: {any}", .{e});
            break :blk false;
        };

        if (chain_handled) {
            if (session.isChainComplete()) {
                // Chain finished — send full panel data to Vim
                log.debug("DAP chain complete, sending panel update", .{});
                const panel_data = session.buildPanelData(alloc) catch return;
                self.sendDapCallbackToOwner(alloc, "yac_dap#on_panel_update", panel_data);
            }
            // Chain-managed responses are NOT forwarded individually —
            // the panel update callback replaces per-response callbacks.
            return;
        }

        // Non-chain responses: forward individually for backward compatibility
        if (std.mem.eql(u8, response.command, "stackTrace") or
            std.mem.eql(u8, response.command, "scopes") or
            std.mem.eql(u8, response.command, "variables") or
            std.mem.eql(u8, response.command, "evaluate") or
            std.mem.eql(u8, response.command, "threads"))
        {
            const func = std.fmt.allocPrint(alloc, "yac_dap#on_{s}", .{response.command}) catch return;
            self.sendDapCallbackToOwner(alloc, func, response.body);
        }
    }

    fn handleDapEvent(self: *EventLoop, alloc: std.mem.Allocator, session: *dap_session_mod.DapSession, event: dap_protocol.DapEvent) void {
        session.client.handleEvent(event);

        if (std.mem.eql(u8, event.event, "initialized")) {
            session.session_state = .configured;
            session.client.sendDeferredConfiguration();
            self.sendDapCallbackToOwner(alloc, "yac_dap#on_initialized", .null);
        } else if (std.mem.eql(u8, event.event, "stopped")) {
            session.session_state = .stopped;
            // Extract reason from event body
            const reason = if (event.body == .object)
                json_utils.getString(event.body.object, "reason") orelse "unknown"
            else
                "unknown";
            // Start chain: stackTrace → scopes → variables (automatic)
            session.startStoppedChain(reason) catch |e| {
                log.err("DAP chain start failed: {any}", .{e});
            };
            self.sendDapCallbackToOwner(alloc, "yac_dap#on_stopped", event.body);
        } else if (std.mem.eql(u8, event.event, "continued")) {
            session.session_state = .running;
            session.clearCache();
            self.sendDapCallbackToOwner(alloc, "yac_dap#on_continued", .null);
        } else if (std.mem.eql(u8, event.event, "terminated")) {
            session.session_state = .terminated;
            self.sendDapCallbackToOwner(alloc, "yac_dap#on_terminated", .null);
            self.cleanupDapSession();
        } else if (std.mem.eql(u8, event.event, "exited")) {
            self.sendDapCallbackToOwner(alloc, "yac_dap#on_exited", event.body);
        } else if (std.mem.eql(u8, event.event, "output")) {
            self.sendDapCallbackToOwner(alloc, "yac_dap#on_output", event.body);
        } else if (std.mem.eql(u8, event.event, "breakpoint")) {
            self.sendDapCallbackToOwner(alloc, "yac_dap#on_breakpoint", event.body);
        } else if (std.mem.eql(u8, event.event, "thread")) {
            self.sendDapCallbackToOwner(alloc, "yac_dap#on_thread", event.body);
        }
    }

    /// Send DAP callback only to the client that owns the session.
    fn sendDapCallbackToOwner(self: *EventLoop, alloc: std.mem.Allocator, func: []const u8, args: Value) void {
        const session = self.dap_session orelse return;
        const owner_id = session.owner_client_id;
        const client_entry = self.clients.get(owner_id) orelse {
            log.warn("DAP callback: owner client {d} disconnected", .{owner_id});
            return;
        };

        var arg_array = std.json.Array.init(alloc);
        arg_array.append(args) catch return;

        const encoded = vim.encodeChannelCommand(alloc, .{ .call_async = .{
            .func = func,
            .args = .{ .array = arg_array },
        } }) catch return;

        const msg = self.allocator.alloc(u8, encoded.len + 1) catch return;
        @memcpy(msg[0..encoded.len], encoded);
        msg[encoded.len] = '\n';
        if (!self.out_queue.push(.{ .stream = client_entry.stream, .bytes = msg })) {
            self.allocator.free(msg);
            log.warn("DAP callback: out queue full for client {d}", .{owner_id});
        }
    }

    fn sendVimExToAll(self: *EventLoop, alloc: std.mem.Allocator, command: []const u8) void {
        var cit = self.clients.iterator();
        while (cit.next()) |entry| {
            const cid = entry.key_ptr.*;
            self.sendVimExTo(cid, alloc, command);
        }
    }

    fn cleanupDapSession(self: *EventLoop) void {
        if (self.dap_session) |session| {
            session.client.deinit();
            session.deinit();
            self.allocator.destroy(session);
            self.dap_session = null;
            log.info("DAP session cleaned up", .{});
        }
    }

    fn handleLspDeath(self: *EventLoop, client_key: []const u8) void {
        log.err("LSP server died: {s}", .{client_key});

        const workspace_uri = lsp_mod.extractWorkspaceFromKey(client_key);

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        // Read stderr for diagnostics
        const stderr_snippet = blk: {
            const client = self.lsp.registry.getClient(client_key) orelse break :blk null;
            const stderr_file = client.child.stderr orelse break :blk null;
            var stderr_buf: [4096]u8 = undefined;
            const n = stderr_file.read(&stderr_buf) catch break :blk null;
            if (n == 0) break :blk null;
            log.err("LSP stderr: {s}", .{stderr_buf[0..n]});
            break :blk stderr_buf[0..@min(n, 200)];
        };

        const crash_msg = if (stderr_snippet) |msg|
            std.fmt.allocPrint(alloc, "[yac] LSP server crashed: {s}", .{msg}) catch return
        else
            "[yac] LSP server crashed (no stderr output)";
        if (lsp_transform.formatToastCmd(alloc, crash_msg, "ErrorMsg")) |cmd|
            self.sendVimExToWorkspace(workspace_uri, alloc, cmd);

        self.lsp.registry.removeClient(client_key);
    }

    /// Handle LSP server notifications.
    fn handleLspNotification(self: *EventLoop, client_key: []const u8, method: []const u8, params: Value) void {
        const workspace_uri = lsp_mod.extractWorkspaceFromKey(client_key);

        if (std.mem.eql(u8, method, "$/progress")) {
            const language = lsp_mod.extractLanguageFromKey(client_key);
            const params_obj = switch (params) {
                .object => |o| o,
                else => return,
            };
            const value_obj = json_utils.getObject(params_obj, "value") orelse return;
            const kind = json_utils.getString(value_obj, "kind") orelse return;

            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const alloc = arena.allocator();

            const token_key: ?[]const u8 = blk: {
                const token_val = params_obj.get("token") orelse break :blk null;
                switch (token_val) {
                    .string => |s| break :blk s,
                    .integer => |i| break :blk std.fmt.allocPrint(alloc, "{d}", .{i}) catch null,
                    else => break :blk null,
                }
            };

            const message = json_utils.getString(value_obj, "message");
            const percentage = json_utils.getInteger(value_obj, "percentage");

            if (std.mem.eql(u8, kind, "begin")) {
                self.lsp.incrementIndexingCount(language);
                const title = json_utils.getString(value_obj, "title");
                if (token_key) |tk| if (title) |t| self.progress.storeTitle(tk, t);
                if (lsp_transform.formatProgressToast(alloc, title, message, percentage)) |echo_cmd| {
                    self.sendVimExToWorkspace(workspace_uri, alloc, echo_cmd);
                }
            } else if (std.mem.eql(u8, kind, "report")) {
                const title = if (token_key) |tk| self.progress.getTitle(tk) else null;
                if (lsp_transform.formatProgressToast(alloc, title, message, percentage)) |echo_cmd| {
                    self.sendVimExToWorkspace(workspace_uri, alloc, echo_cmd);
                }
            } else if (std.mem.eql(u8, kind, "end")) {
                if (token_key) |tk| self.progress.removeTitle(tk);
                self.lsp.decrementIndexingCount(language);
                if (!self.lsp.isAnyLanguageIndexing()) {
                    if (lsp_transform.formatToastCmd(alloc, "[yac] Indexing complete", null)) |cmd|
                        self.sendVimExToWorkspace(workspace_uri, alloc, cmd);
                    self.flushDeferredRequests();
                }
            }
        } else if (std.mem.eql(u8, method, "textDocument/publishDiagnostics")) {
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const encoded = vim.encodeJsonRpcNotification(arena.allocator(), "diagnostics", params) catch return;
            self.sendToWorkspace(workspace_uri, encoded);
        } else {
            log.debug("LSP notification: {s}", .{method});
        }
    }

    /// Flush deferred requests after LSP indexing completes.
    /// Re-routes each deferred line back to the appropriate work queue.
    fn flushDeferredRequests(self: *EventLoop) void {
        var requests = self.lsp.takeDeferredRequests();
        defer {
            for (requests.items) |req| self.allocator.free(req.raw_line);
            requests.deinit(self.allocator);
        }

        for (requests.items) |req| {
            const client = self.clients.get(req.client_id) orelse continue;
            // Duplicate raw_line since the defer block above frees the original.
            const raw_line_copy = self.allocator.dupe(u8, req.raw_line) catch continue;
            const item = queue_mod.WorkItem{
                .client_id = req.client_id,
                .client_stream = client.stream,
                .raw_line = raw_line_copy,
            };
            // Re-apply the same routing logic as processClientInput.
            const routed = if (queue_mod.isTsMethod(req.raw_line))
                self.in_ts.push(item)
            else
                self.in_general.push(item);
            if (!routed) {
                item.deinit(self.allocator);
                log.warn("Work queue full, dropping deferred request", .{});
            }
        }
    }

    // ====================================================================
    // Send helpers — push to out_queue instead of writing directly.
    // All callers must hold state_lock when accessing clients map.
    // ====================================================================

    /// GPA-allocate message bytes (encoded + newline) and push to out_queue.
    /// Drops the message silently if the queue is full (back-pressure).
    fn pushToOutQueue(self: *EventLoop, stream: std.net.Stream, encoded: []const u8) void {
        const msg_bytes = self.allocator.alloc(u8, encoded.len + 1) catch {
            log.err("OOM: failed to allocate out message", .{});
            return;
        };
        @memcpy(msg_bytes[0..encoded.len], encoded);
        msg_bytes[encoded.len] = '\n';
        if (!self.out_queue.push(.{ .stream = stream, .bytes = msg_bytes })) {
            self.allocator.free(msg_bytes);
            log.warn("Out queue full, dropping message", .{});
        }
    }

    /// Send a JSON-RPC response to a specific Vim client.
    fn sendVimResponseTo(self: *EventLoop, cid: ClientId, alloc: Allocator, vim_id: ?u64, result: Value) void {
        const id = vim_id orelse return;
        const client = self.clients.get(cid) orelse return;
        const encoded = vim.encodeJsonRpcResponse(alloc, @intCast(id), result) catch return;
        defer alloc.free(encoded);
        self.pushToOutQueue(client.stream, encoded);
    }

    /// Send a Vim ex command to a specific client.
    fn sendVimExTo(self: *EventLoop, cid: ClientId, alloc: Allocator, command: []const u8) void {
        const client = self.clients.get(cid) orelse return;
        const encoded = vim.encodeChannelCommand(alloc, .{ .ex = .{ .command = command } }) catch return;
        defer alloc.free(encoded);
        self.pushToOutQueue(client.stream, encoded);
    }

    /// Send an expr request to a specific Vim client and register a pending entry.
    fn sendVimExprTo(self: *EventLoop, cid: ClientId, alloc: Allocator, vim_id: ?u64, expr: []const u8, tag: PendingVimExpr.Tag) void {
        const client = self.clients.get(cid) orelse return;
        const id = self.requests.nextExprId();
        // Register pending entry BEFORE sending, so we never send an expr we can't track
        self.requests.addExpr(id, .{ .cid = cid, .vim_id = vim_id, .tag = tag }) catch {
            log.err("Failed to register pending vim expr (OOM)", .{});
            return;
        };
        const encoded = vim.encodeChannelCommand(alloc, .{ .expr = .{ .expr = expr, .id = id } }) catch return;
        defer alloc.free(encoded);
        self.pushToOutQueue(client.stream, encoded);
    }

    /// Handle the result of a daemon->Vim expr request.
    fn handleVimExprResponse(self: *EventLoop, alloc: Allocator, pending: PendingVimExpr, result: Value) void {
        switch (pending.tag) {
            .picker_buffers => {
                if (!self.picker.hasIndex()) return;
                const arr = switch (result) {
                    .array => |a| a.items,
                    else => &[_]Value{},
                };
                for (arr) |item| {
                    if (item == .string) self.picker.appendIfMissing(item.string);
                }
                self.sendVimResponseTo(pending.cid, alloc, pending.vim_id, picker_mod.buildPickerResults(alloc, self.picker.recentFiles(), "file"));
            },
        }
    }

    /// After did_save, tell other clients in the same workspace to checktime
    /// so they reload externally modified files immediately.
    fn broadcastChecktimeToOthers(self: *EventLoop, sender_cid: ClientId, alloc: Allocator, params: Value) void {
        const obj = switch (params) {
            .object => |o| o,
            else => return,
        };
        const file = json_utils.getString(obj, "file") orelse return;
        const real_path = lsp_registry_mod.extractRealPath(file);
        const language = lsp_registry_mod.LspRegistry.detectLanguage(real_path) orelse return;
        const client_result = self.lsp.registry.findClient(language, real_path) orelse return;
        const workspace_uri = lsp_mod.extractWorkspaceFromKey(client_result.client_key) orelse return;

        const encoded = vim.encodeChannelCommand(alloc, .{ .ex = .{ .command = "silent! checktime" } }) catch return;
        defer alloc.free(encoded);

        var cit = self.clients.valueIterator();
        while (cit.next()) |client_ptr| {
            if (client_ptr.*.id != sender_cid and client_ptr.*.isSubscribedTo(workspace_uri)) {
                self.pushToOutQueue(client_ptr.*.stream, encoded);
            }
        }
    }

    /// Send a raw encoded message to clients subscribed to a workspace.
    /// Falls back to broadcast if workspace_uri is null (e.g. copilot notifications).
    fn sendToWorkspace(self: *EventLoop, workspace_uri: ?[]const u8, encoded: []const u8) void {
        if (workspace_uri == null) {
            self.broadcastRaw(encoded);
            return;
        }
        var cit = self.clients.valueIterator();
        while (cit.next()) |client_ptr| {
            if (client_ptr.*.isSubscribedTo(workspace_uri.?)) {
                self.pushToOutQueue(client_ptr.*.stream, encoded);
            }
        }
    }

    /// Send a Vim ex command to clients subscribed to a workspace.
    fn sendVimExToWorkspace(self: *EventLoop, workspace_uri: ?[]const u8, alloc: Allocator, command: []const u8) void {
        const encoded = vim.encodeChannelCommand(alloc, .{ .ex = .{ .command = command } }) catch return;
        defer alloc.free(encoded);
        self.sendToWorkspace(workspace_uri, encoded);
    }

    /// Send a Vim ex command to ALL connected clients.
    fn broadcastVimEx(self: *EventLoop, alloc: Allocator, command: []const u8) void {
        const encoded = vim.encodeChannelCommand(alloc, .{ .ex = .{ .command = command } }) catch return;
        defer alloc.free(encoded);
        self.broadcastRaw(encoded);
    }

    /// Broadcast a raw encoded message to all connected clients.
    fn broadcastRaw(self: *EventLoop, encoded: []const u8) void {
        var cit = self.clients.valueIterator();
        while (cit.next()) |client_ptr| {
            self.pushToOutQueue(client_ptr.*.stream, encoded);
        }
    }

    /// Send an error response to a specific Vim client.
    fn sendVimErrorTo(self: *EventLoop, cid: ClientId, alloc: Allocator, vim_id: ?u64, message: []const u8) void {
        if (vim_id) |id| {
            var err_obj = ObjectMap.init(alloc);
            err_obj.put("error", json_utils.jsonString(message)) catch return;
            self.sendVimResponseTo(cid, alloc, id, .{ .object = err_obj });
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
