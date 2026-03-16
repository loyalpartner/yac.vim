const std = @import("std");
const json_utils = @import("json_utils.zig");
const vim = @import("vim_protocol.zig");
const rpc = @import("rpc.zig");
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
const dap_session_mod = @import("dap/session.zig");
const vim_transport_mod = @import("vim_transport.zig");
const dap_bridge_mod = @import("dap_bridge.zig");
const lsp_bridge_mod = @import("lsp_bridge.zig");

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

    pub fn lspBridge(self: *EventLoop) lsp_bridge_mod.LspBridge {
        return .{
            .allocator = self.allocator,
            .lsp = &self.lsp,
            .progress = &self.progress,
            .in_general = &self.in_general,
            .in_ts = &self.in_ts,
            .transport = self.transport(),
        };
    }

    pub fn dapBridge(self: *EventLoop) dap_bridge_mod.DapBridge {
        return .{
            .allocator = self.allocator,
            .dap_session = &self.dap_session,
            .transport = self.transport(),
        };
    }

    pub fn transport(self: *EventLoop) vim_transport_mod.VimTransport {
        return .{
            .allocator = self.allocator,
            .out_queue = &self.out_queue,
            .clients = &self.clients,
            .requests = &self.requests,
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
            self.lspBridge().handleFds(poll_fds.items, poll_setup.client_count, poll_client_keys.items);
            self.dapBridge().handleFd(poll_fds.items, poll_setup.dap_fd_index);
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
        const msg = rpc.Message.deserialize(alloc, arr) catch |e| {
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
                            self.transport().sendExTo(cid, alloc, cmd);
                    }
                    return;
                }
            }
        }

        var ctx = handlers_mod.HandlerContext{
            .allocator = alloc,
            .gpa_allocator = self.allocator,
            .registry = &self.lsp.registry,
            .lsp_state = &self.lsp,
            .client_stream = client_stream,
            .client_id = cid,
            .ts = &self.ts,
            .dap_session = &self.dap_session,
            .out_queue = &self.out_queue,
            .shutdown_flag = &self.shutdown_requested,
        };

        const result = handlers_mod.dispatch(&ctx, method, params) catch |e| {
            log.err("Handler error for {s}: {any}", .{ method, e });
            self.transport().sendErrorTo(cid, alloc, vim_id, "Handler error");
            return;
        };

        // Route based on framework state set by the handler.
        // Priority: deferred > pending_lsp > subscribe + data > data > null
        if (ctx._deferred) {
            if (vim_id != null) {
                if (self.lsp.enqueueDeferred(cid, raw_line)) {
                    log.info("Deferred {s} request (LSP initializing)", .{method});
                    if (lsp_transform.formatToastCmd(alloc, "[yac] LSP initializing, request queued...", null)) |cmd|
                        self.transport().sendExTo(cid, alloc, cmd);
                } else {
                    self.transport().sendResponseTo(cid, alloc, vim_id, .null);
                }
            }
        } else if (ctx._pending) |pending| {
            self.trackPendingRequest(pending.request_id, cid, vim_id, method, params, pending.client_key, pending.transform);
        } else if (result) |data| {
            if (ctx._subscribe_workspace) |ws| {
                self.clients.subscribeClient(cid, ws);
            }
            switch (self.picker.processAction(alloc, data)) {
                .none => self.transport().sendResponseTo(cid, alloc, vim_id, data),
                .respond_null => self.transport().sendResponseTo(cid, alloc, vim_id, .null),
                .respond => |v| self.transport().sendResponseTo(cid, alloc, vim_id, v),
                .query_buffers => self.transport().sendExprTo(cid, alloc, vim_id, "map(getbufinfo({'buflisted':1}), {_, b -> b.name})", .picker_buffers),
            }
        } else {
            if (vim_id != null) {
                self.transport().sendResponseTo(cid, alloc, vim_id, .null);
            }
        }

        // After did_save: notify other clients in the same workspace to reload
        if (std.mem.eql(u8, method, "did_save")) {
            self.broadcastChecktimeToOthers(cid, alloc, params);
        }
    }

    /// Track a pending LSP request so the response can be routed back to the correct Vim client.
    fn trackPendingRequest(self: *EventLoop, lsp_request_id: u32, cid: ClientId, vim_id: ?u64, method: []const u8, params: Value, client_key: ?[]const u8, transform: lsp_transform.TransformFn) void {
        const params_obj: ?ObjectMap = switch (params) {
            .object => |o| o,
            else => null,
        };
        const file = if (params_obj) |obj| json_utils.getString(obj, "file") else null;

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
                    self.transport().sendResponseTo(info.client_id, self.allocator, info.vim_request_id, .null);
                }
                log.debug("Cancelled {d} old {s} request(s)", .{ cancelled.lsp_ids.items.len, method });
            }
        }

        const method_owned = self.allocator.dupe(u8, method) catch |e| {
            log.err("Failed to track pending request: {any}", .{e});
            return;
        };
        const file_owned = if (file) |f|
            self.allocator.dupe(u8, f) catch |e| {
                self.allocator.free(method_owned);
                log.err("Failed to track pending request: {any}", .{e});
                return;
            }
        else
            null;
        const client_key_owned = if (client_key) |key|
            self.allocator.dupe(u8, key) catch |e| {
                self.allocator.free(method_owned);
                if (file_owned) |f| self.allocator.free(f);
                log.err("Failed to track pending request: {any}", .{e});
                return;
            }
        else
            null;

        self.requests.addLsp(lsp_request_id, .{
            .vim_request_id = vim_id,
            .method = method_owned,
            .file = file_owned,
            .client_id = cid,
            .lsp_client_key = client_key_owned,
            .transform = transform,
        }) catch |e| {
            self.allocator.free(method_owned);
            if (file_owned) |f| self.allocator.free(f);
            if (client_key_owned) |k| self.allocator.free(k);
            log.err("Failed to track pending request: {any}", .{e});
        };
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
                self.transport().sendResponseTo(pending.cid, alloc, pending.vim_id, picker_mod.buildPickerResults(alloc, self.picker.recentFiles(), "file"));
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
                self.transport().pushToOutQueue(client_ptr.*.stream, encoded);
            }
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
