const std = @import("std");
const json_utils = @import("json_utils.zig");
const vim = @import("vim_protocol.zig");
const lsp_client_mod = @import("lsp_client.zig");
const lsp_registry_mod = @import("lsp_registry.zig");
const handlers_mod = @import("handlers.zig");
const picker_mod = @import("picker.zig");
const log = @import("log.zig");

const Allocator = std.mem.Allocator;
const Value = json_utils.Value;
const ObjectMap = json_utils.ObjectMap;

// ============================================================================
// Client ID and VimClient — each connected Vim instance
// ============================================================================

const ClientId = u32;

const VimClient = struct {
    id: ClientId,
    stream: std.net.Stream,
    read_buf: std.ArrayList(u8),

    fn init(id: ClientId, stream: std.net.Stream) VimClient {
        return .{
            .id = id,
            .stream = stream,
            .read_buf = .{},
        };
    }

    fn deinit(self: *VimClient, allocator: Allocator) void {
        self.read_buf.deinit(allocator);
        self.stream.close();
    }
};

// ============================================================================
// Pending LSP Request Tracking
//
// Maps (language, lsp_request_id) -> vim_request info so we can route
// LSP responses back to the original Vim request.
// ============================================================================

const PendingLspRequest = struct {
    vim_request_id: ?u64,
    method: []const u8,
    ssh_host: ?[]const u8,
    file: ?[]const u8,
    client_id: ClientId,

    fn deinit(self: PendingLspRequest, allocator: Allocator) void {
        allocator.free(self.method);
        if (self.ssh_host) |ssh_host| allocator.free(ssh_host);
        if (self.file) |file| allocator.free(file);
    }
};

// ============================================================================
// Socket path helper
// ============================================================================

fn getSocketPath(buf: []u8) []const u8 {
    if (std.posix.getenv("XDG_RUNTIME_DIR")) |xdg| {
        return std.fmt.bufPrint(buf, "{s}/yac-lsp-bridge.sock", .{xdg}) catch "/tmp/yac-lsp-bridge.sock";
    }
    if (std.posix.getenv("USER")) |user| {
        return std.fmt.bufPrint(buf, "/tmp/yac-lsp-bridge-{s}.sock", .{user}) catch "/tmp/yac-lsp-bridge.sock";
    }
    return "/tmp/yac-lsp-bridge.sock";
}

// ============================================================================
// Event Loop — multi-client daemon
// ============================================================================

const PendingVimExpr = struct {
    cid: ClientId,
    vim_id: ?u64,
    tag: Tag,

    const Tag = enum { picker_buffers };
};

const IDLE_TIMEOUT_NS: i128 = 60 * std.time.ns_per_s;

const EventLoop = struct {
    allocator: Allocator,
    registry: lsp_registry_mod.LspRegistry,
    listener: std.net.Server,
    clients: std.AutoHashMap(ClientId, *VimClient),
    next_client_id: ClientId,
    /// Maps lsp_request_id -> pending Vim request context
    pending_requests: std.AutoHashMap(u32, PendingLspRequest),
    /// Per-language count of active LSP $/progress operations (indexing, etc.)
    indexing_counts: std.StringHashMap(u32),
    /// Vim requests deferred while LSP is indexing, replayed when ready
    deferred_requests: std.ArrayList(DeferredRequest),
    /// Maps progress token -> title (from $/progress begin, used for report events)
    progress_titles: std.StringHashMap([]const u8),
    /// Timestamp (nanos) when daemon should exit if no clients; null = has clients
    idle_deadline: ?i128,
    /// Picker file index (active while picker is open)
    file_index: ?*picker_mod.FileIndex,
    /// Maps expr_id -> pending vim expr context (for daemon→Vim expr requests)
    pending_vim_exprs: std.AutoHashMap(i64, PendingVimExpr),
    /// Next ID for daemon→Vim expr requests (start high to avoid collision with Vim request IDs)
    next_expr_id: i64,

    const max_deferred_requests = 50;
    const deferred_ttl_ns: i128 = 10 * std.time.ns_per_s;

    const DeferredRequest = struct {
        client_id: ClientId,
        raw_line: []u8,
        timestamp_ns: i128,
    };

    fn init(allocator: Allocator, listener: std.net.Server) EventLoop {
        return .{
            .allocator = allocator,
            .registry = lsp_registry_mod.LspRegistry.init(allocator),
            .listener = listener,
            .clients = std.AutoHashMap(ClientId, *VimClient).init(allocator),
            .next_client_id = 1,
            .pending_requests = std.AutoHashMap(u32, PendingLspRequest).init(allocator),
            .indexing_counts = std.StringHashMap(u32).init(allocator),
            .deferred_requests = .{},
            .progress_titles = std.StringHashMap([]const u8).init(allocator),
            .idle_deadline = std.time.nanoTimestamp(),
            .file_index = null,
            .pending_vim_exprs = std.AutoHashMap(i64, PendingVimExpr).init(allocator),
            .next_expr_id = 100000,
        };
    }

    fn deinit(self: *EventLoop) void {
        var it = self.pending_requests.valueIterator();
        while (it.next()) |pending| {
            pending.deinit(self.allocator);
        }
        self.registry.shutdownAll();
        self.registry.deinit();
        self.pending_requests.deinit();
        {
            var icit = self.indexing_counts.iterator();
            while (icit.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
            }
            self.indexing_counts.deinit();
        }
        {
            var cit = self.clients.valueIterator();
            while (cit.next()) |client_ptr| {
                client_ptr.*.deinit(self.allocator);
                self.allocator.destroy(client_ptr.*);
            }
            self.clients.deinit();
        }
        for (self.deferred_requests.items) |req| self.allocator.free(req.raw_line);
        self.deferred_requests.deinit(self.allocator);
        {
            var pit = self.progress_titles.iterator();
            while (pit.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.*);
            }
            self.progress_titles.deinit();
        }
        if (self.file_index) |fi| {
            fi.deinit();
            self.allocator.destroy(fi);
        }
        self.pending_vim_exprs.deinit();
        self.listener.deinit();
    }

    /// Main event loop using poll().
    fn run(self: *EventLoop) !void {
        var buf: [8192]u8 = undefined;

        log.info("Entering event loop (daemon mode)", .{});
        // Set idle deadline since we start with no clients
        self.idle_deadline = std.time.nanoTimestamp() + IDLE_TIMEOUT_NS;

        while (true) {
            // Build poll fd list: listener + all client fds + all LSP stdout fds
            var poll_fds: std.ArrayList(std.posix.pollfd) = .{};
            defer poll_fds.deinit(self.allocator);
            var poll_client_keys: std.ArrayList([]const u8) = .{};
            defer poll_client_keys.deinit(self.allocator);

            // Collect client IDs in fd order for indexing
            var client_id_order: std.ArrayList(ClientId) = .{};
            defer client_id_order.deinit(self.allocator);

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
            try self.registry.collectFds(&poll_fds, &poll_client_keys);

            // fd[N+M+1] = picker fd/find stdout (if active)
            const picker_fd_index: ?usize = blk: {
                if (self.file_index) |fi| {
                    if (fi.getStdoutFd()) |fd| {
                        const idx = poll_fds.items.len;
                        try poll_fds.append(self.allocator, .{
                            .fd = fd,
                            .events = std.posix.POLL.IN,
                            .revents = 0,
                        });
                        break :blk idx;
                    }
                }
                break :blk null;
            };

            // Calculate timeout
            const poll_timeout: i32 = blk: {
                if (self.idle_deadline) |deadline| {
                    const now = std.time.nanoTimestamp();
                    const remaining_ns = deadline - now;
                    if (remaining_ns <= 0) break :blk 0;
                    const remaining_ms: i32 = @intCast(@min(@divTrunc(remaining_ns, std.time.ns_per_ms), 100));
                    break :blk remaining_ms;
                }
                break :blk 100;
            };

            const ready = std.posix.poll(poll_fds.items, poll_timeout) catch |e| {
                log.err("poll failed: {any}", .{e});
                continue;
            };

            if (ready == 0) {
                // Check idle timeout
                if (self.idle_deadline) |deadline| {
                    if (std.time.nanoTimestamp() >= deadline and self.clients.count() == 0) {
                        log.info("Idle timeout reached with no clients, shutting down", .{});
                        break;
                    }
                }
                continue;
            }

            // Check listener (new client connections)
            if (poll_fds.items[0].revents & std.posix.POLL.IN != 0) {
                self.acceptClient();
            }

            // Check client fds
            for (poll_fds.items[1 .. 1 + client_count], 0..) |pfd, i| {
                const cid = client_id_order.items[i];

                if (pfd.revents & std.posix.POLL.IN != 0) {
                    const client = self.clients.get(cid) orelse continue;
                    const n = std.posix.read(client.stream.handle, &buf) catch |e| {
                        log.err("client {d} read failed: {any}", .{ cid, e });
                        self.removeClient(cid);
                        continue;
                    };
                    if (n == 0) {
                        log.info("client {d} EOF, disconnecting", .{cid});
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

            // Check LSP server stdouts
            const lsp_end = 1 + client_count + poll_client_keys.items.len;
            for (poll_fds.items[1 + client_count .. lsp_end], 0..) |pfd, i| {
                if (pfd.revents & std.posix.POLL.IN != 0) {
                    const client_key = poll_client_keys.items[i];
                    self.processLspOutput(client_key);
                }
                if (pfd.revents & (std.posix.POLL.HUP | std.posix.POLL.ERR) != 0) {
                    const dead_key = poll_client_keys.items[i];
                    self.handleLspDeath(dead_key);
                }
            }

            // Check picker fd
            if (picker_fd_index) |pfi| {
                if (poll_fds.items[pfi].revents & (std.posix.POLL.IN | std.posix.POLL.HUP) != 0) {
                    if (self.file_index) |fi| {
                        _ = fi.pollScan();
                    }
                }
            }
        }
    }

    /// Accept a new Vim client connection.
    fn acceptClient(self: *EventLoop) void {
        const conn = self.listener.accept() catch |e| {
            log.err("accept failed: {any}", .{e});
            return;
        };

        const cid = self.next_client_id;
        self.next_client_id += 1;

        const client = self.allocator.create(VimClient) catch |e| {
            log.err("failed to allocate client: {any}", .{e});
            conn.stream.close();
            return;
        };
        client.* = VimClient.init(cid, conn.stream);

        self.clients.put(cid, client) catch |e| {
            log.err("failed to register client: {any}", .{e});
            client.deinit(self.allocator);
            self.allocator.destroy(client);
            return;
        };

        // Clear idle deadline — we have a client now
        self.idle_deadline = null;
        log.info("Client {d} connected (total: {d})", .{ cid, self.clients.count() });
    }

    /// Remove a disconnected client and clean up.
    fn removeClient(self: *EventLoop, cid: ClientId) void {
        // Remove pending LSP requests for this client
        var to_remove: std.ArrayList(u32) = .{};
        defer to_remove.deinit(self.allocator);

        var pit = self.pending_requests.iterator();
        while (pit.next()) |entry| {
            if (entry.value_ptr.client_id == cid) {
                to_remove.append(self.allocator, entry.key_ptr.*) catch {};
            }
        }
        for (to_remove.items) |req_id| {
            if (self.pending_requests.fetchRemove(req_id)) |entry| {
                entry.value.deinit(self.allocator);
            }
        }

        // Remove deferred requests for this client
        var i: usize = 0;
        while (i < self.deferred_requests.items.len) {
            if (self.deferred_requests.items[i].client_id == cid) {
                self.allocator.free(self.deferred_requests.items[i].raw_line);
                _ = self.deferred_requests.swapRemove(i);
            } else {
                i += 1;
            }
        }

        if (self.clients.fetchRemove(cid)) |entry| {
            entry.value.deinit(self.allocator);
            self.allocator.destroy(entry.value);
        }

        log.info("Client {d} removed (remaining: {d})", .{ cid, self.clients.count() });

        // Set idle deadline if no clients remain
        if (self.clients.count() == 0) {
            self.idle_deadline = std.time.nanoTimestamp() + IDLE_TIMEOUT_NS;
            log.info("No clients, will exit in 60s", .{});
        }
    }

    /// Process buffered input from a specific client.
    fn processClientInput(self: *EventLoop, cid: ClientId) void {
        while (true) {
            const client = self.clients.get(cid) orelse break;
            const newline_pos = std.mem.indexOf(u8, client.read_buf.items, "\n") orelse break;

            const line = client.read_buf.items[0..newline_pos];
            if (line.len > 0) {
                self.handleVimLine(cid, line);
            }

            // Remove processed line from buffer
            // Re-fetch client since handleVimLine could have removed it
            const c = self.clients.get(cid) orelse break;
            const remaining = c.read_buf.items.len - newline_pos - 1;
            if (remaining > 0) {
                std.mem.copyForwards(u8, c.read_buf.items[0..remaining], c.read_buf.items[newline_pos + 1 ..]);
            }
            c.read_buf.shrinkRetainingCapacity(remaining);
        }
    }

    /// Handle a single JSON line from a Vim client.
    fn handleVimLine(self: *EventLoop, cid: ClientId, line: []const u8) void {
        const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
        if (trimmed.len == 0) return;

        // Per-request arena allocator
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

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
            if (self.pending_vim_exprs.fetchRemove(arr[0].integer)) |entry| {
                self.handleVimExprResponse(alloc, entry.value, arr[1]);
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
                log.debug("Vim[{d}] request [{d}]: {s}", .{ cid, r.id, r.method });
                self.handleVimRequest(cid, alloc, r.id, r.method, r.params, trimmed);
            },
            .notification => |n| {
                log.debug("Vim[{d}] notification: {s}", .{ cid, n.method });
                self.handleVimRequest(cid, alloc, null, n.method, n.params, trimmed);
            },
            .response => |r| {
                log.debug("Vim[{d}] response [{d}]", .{ cid, r.id });
                // Responses to our outgoing calls - currently not tracked
            },
        }
    }

    /// Handle a Vim request or notification.
    fn handleVimRequest(self: *EventLoop, cid: ClientId, alloc: Allocator, vim_id: ?u64, method: []const u8, params: Value, raw_line: []const u8) void {
        // Defer query methods while the relevant LSP server is indexing
        const request_language: ?[]const u8 = if (isQueryMethod(method)) blk: {
            const obj = switch (params) { .object => |o| o, else => break :blk null };
            const file = json_utils.getString(obj, "file") orelse break :blk null;
            break :blk lsp_registry_mod.LspRegistry.detectLanguage(lsp_registry_mod.extractRealPath(file));
        } else null;
        if (vim_id != null and request_language != null and self.isLanguageIndexing(request_language.?)) {
            const duped = self.allocator.dupe(u8, raw_line) catch |e| {
                log.err("Failed to defer request: {any}", .{e});
                return;
            };
            // Evict oldest if queue is full
            if (self.deferred_requests.items.len >= max_deferred_requests) {
                self.allocator.free(self.deferred_requests.items[0].raw_line);
                _ = self.deferred_requests.orderedRemove(0);
                log.info("Evicted oldest deferred request (queue full)", .{});
            }
            self.deferred_requests.append(self.allocator, .{ .client_id = cid, .raw_line = duped, .timestamp_ns = std.time.nanoTimestamp() }) catch |e| {
                self.allocator.free(duped);
                log.err("Failed to defer request: {any}", .{e});
                return;
            };
            log.info("Deferred {s} request (LSP indexing in progress)", .{method});
            self.sendVimExTo(cid, alloc, "echo '[yac] LSP indexing, request queued...'");
            return;
        }

        const client = self.clients.get(cid) orelse return;

        var ctx = handlers_mod.HandlerContext{
            .allocator = alloc,
            .registry = &self.registry,
            .client_stream = client.stream,
        };

        const result = handlers_mod.dispatch(&ctx, method, params) catch |e| {
            log.err("Handler error for {s}: {any}", .{ method, e });
            self.sendVimErrorTo(cid, alloc, vim_id, "Handler error");
            return;
        };

        switch (result) {
            .data => |data| {
                if (self.handlePickerAction(cid, alloc, vim_id, data)) return;
                self.sendVimResponseTo(cid, alloc, vim_id, data);
            },
            .empty => {
                if (vim_id != null) {
                    self.sendVimResponseTo(cid, alloc, vim_id, .null);
                }
            },
            .initializing => {
                if (vim_id != null) {
                    const duped = self.allocator.dupe(u8, raw_line) catch |e| {
                        log.err("Failed to defer initializing request: {any}", .{e});
                        self.sendVimResponseTo(cid, alloc, vim_id, .null);
                        return;
                    };
                    if (self.deferred_requests.items.len >= max_deferred_requests) {
                        self.allocator.free(self.deferred_requests.items[0].raw_line);
                        _ = self.deferred_requests.orderedRemove(0);
                    }
                    self.deferred_requests.append(self.allocator, .{ .client_id = cid, .raw_line = duped, .timestamp_ns = std.time.nanoTimestamp() }) catch |e| {
                        self.allocator.free(duped);
                        log.err("Failed to defer initializing request: {any}", .{e});
                        self.sendVimResponseTo(cid, alloc, vim_id, .null);
                        return;
                    };
                    log.info("Deferred {s} request (LSP initializing)", .{method});
                    self.sendVimExTo(cid, alloc, "echo '[yac] LSP initializing, request queued...'");
                }
            },
            .pending_lsp => |pending| {
                self.trackPendingRequest(pending.lsp_request_id, cid, vim_id, method, params);
            },
        }
    }

    /// Track a pending LSP request so the response can be routed back to the correct Vim client.
    fn trackPendingRequest(self: *EventLoop, lsp_request_id: u32, cid: ClientId, vim_id: ?u64, method: []const u8, params: Value) void {
        const params_obj: ?ObjectMap = switch (params) {
            .object => |o| o,
            else => null,
        };
        const file = if (params_obj) |obj| json_utils.getString(obj, "file") else null;
        const ssh_host = if (file) |f| lsp_registry_mod.extractSshHost(f) else null;

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

        self.pending_requests.put(lsp_request_id, .{
            .vim_request_id = vim_id,
            .method = method_owned,
            .ssh_host = ssh_host_owned,
            .file = file_owned,
            .client_id = cid,
        }) catch |e| {
            self.allocator.free(method_owned);
            if (ssh_host_owned) |h| self.allocator.free(h);
            if (file_owned) |f| self.allocator.free(f);
            log.err("Failed to track pending request: {any}", .{e});
        };
    }

    /// Process output from an LSP server.
    fn processLspOutput(self: *EventLoop, client_key: []const u8) void {
        const client = self.registry.getClient(client_key) orelse return;

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
                    if (self.registry.getInitRequestId(client_key)) |init_id| {
                        if (resp.id == init_id) {
                            self.registry.handleInitializeResponse(client_key) catch |e| {
                                log.err("Failed to handle init response: {any}", .{e});
                            };
                            if (!self.isAnyLanguageIndexing()) {
                                self.flushDeferredRequests();
                            }
                            continue;
                        }
                    }

                    // Route to pending Vim request
                    if (self.pending_requests.fetchRemove(resp.id)) |entry| {
                        const pending = entry.value;
                        defer pending.deinit(self.allocator);

                        var arena = std.heap.ArenaAllocator.init(self.allocator);
                        defer arena.deinit();

                        if (resp.err) |err_val| {
                            log.err("LSP error for request {d}: {any}", .{ resp.id, err_val });
                            self.sendVimResponseTo(pending.client_id, arena.allocator(), pending.vim_request_id, .null);
                        } else {
                            const transformed = transformLspResult(
                                arena.allocator(),
                                pending.method,
                                resp.result,
                                pending.ssh_host,
                            );
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
        const lsp_client = self.registry.getClient(client_key) orelse return;

        if (std.mem.eql(u8, method, "workspace/applyEdit")) {
            // Acknowledge the edit request
            var result_obj = ObjectMap.init(self.allocator);
            result_obj.put("applied", json_utils.jsonBool(true)) catch {};
            lsp_client.sendResponse(id, .{ .object = result_obj }) catch |e| {
                log.err("Failed to respond to workspace/applyEdit: {any}", .{e});
            };

            // Forward the edit to all Vim clients as a notification
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const encoded = vim.encodeJsonRpcNotification(arena.allocator(), "applyEdit", params) catch return;
            self.broadcastRaw(encoded);
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
    fn handleLspDeath(self: *EventLoop, client_key: []const u8) void {
        log.err("LSP server died: {s}", .{client_key});

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        // Read stderr for diagnostics
        const stderr_snippet = blk: {
            const client = self.registry.getClient(client_key) orelse break :blk null;
            const stderr_file = client.child.stderr orelse break :blk null;
            var stderr_buf: [4096]u8 = undefined;
            const n = stderr_file.read(&stderr_buf) catch break :blk null;
            if (n == 0) break :blk null;
            log.err("LSP stderr: {s}", .{stderr_buf[0..n]});
            break :blk stderr_buf[0..@min(n, 200)];
        };

        if (stderr_snippet) |msg| {
            const echo_msg = std.fmt.allocPrint(alloc, "echohl ErrorMsg | echo '[yac] LSP server crashed: {s}' | echohl None", .{msg}) catch return;
            self.broadcastVimEx(alloc, echo_msg);
        } else {
            self.broadcastVimEx(alloc, "echohl ErrorMsg | echo '[yac] LSP server crashed (no stderr output)' | echohl None");
        }

        self.registry.removeClient(client_key);
    }

    /// Transform an LSP response into the format Vim expects.
    fn transformLspResult(alloc: Allocator, method: []const u8, result: Value, ssh_host: ?[]const u8) Value {
        if (std.mem.startsWith(u8, method, "goto_")) {
            return transformGotoResult(alloc, result, ssh_host) catch .null;
        }
        if (std.mem.eql(u8, method, "picker_query")) {
            return transformPickerSymbolResult(alloc, result, ssh_host) catch .null;
        }

        return result;
    }

    /// Transform workspace/symbol or documentSymbol LSP results into picker format.
    fn transformPickerSymbolResult(alloc: Allocator, result: Value, ssh_host: ?[]const u8) !Value {
        const arr = switch (result) {
            .array => |a| a.items,
            else => return .null,
        };

        var items = std.json.Array.init(alloc);
        for (arr) |sym_val| {
            const sym = switch (sym_val) {
                .object => |o| o,
                else => continue,
            };
            const name = json_utils.getString(sym, "name") orelse continue;
            const kind_int = json_utils.getInteger(sym, "kind");
            const container = json_utils.getString(sym, "containerName");
            const detail = if (container) |c|
                std.fmt.allocPrint(alloc, "{s} ({s})", .{ symbolKindName(kind_int), c }) catch ""
            else
                symbolKindName(kind_int);

            // Extract location
            var file: []const u8 = "";
            var line: i64 = 0;
            var column: i64 = 0;
            if (json_utils.getObject(sym, "location")) |loc| {
                if (json_utils.getString(loc, "uri")) |uri| {
                    file = lsp_registry_mod.uriToFilePath(uri) orelse "";
                    if (ssh_host) |host| {
                        file = std.fmt.allocPrint(alloc, "scp://{s}/{s}", .{ host, file }) catch file;
                    }
                }
                if (json_utils.getObject(loc, "range")) |range| {
                    if (json_utils.getObject(range, "start")) |start| {
                        line = json_utils.getInteger(start, "line") orelse 0;
                        column = json_utils.getInteger(start, "character") orelse 0;
                    }
                }
            }

            var item = ObjectMap.init(alloc);
            try item.put("label", json_utils.jsonString(name));
            try item.put("detail", json_utils.jsonString(detail));
            try item.put("file", json_utils.jsonString(file));
            try item.put("line", json_utils.jsonInteger(line));
            try item.put("column", json_utils.jsonInteger(column));
            try items.append(.{ .object = item });
        }

        var result_obj = ObjectMap.init(alloc);
        try result_obj.put("items", .{ .array = items });
        try result_obj.put("mode", json_utils.jsonString("symbol"));
        return .{ .object = result_obj };
    }

    fn symbolKindName(kind: ?i64) []const u8 {
        const k = kind orelse return "Symbol";
        return switch (k) {
            1 => "File", 2 => "Module", 3 => "Namespace", 4 => "Package",
            5 => "Class", 6 => "Method", 7 => "Property", 8 => "Field",
            9 => "Constructor", 10 => "Enum", 11 => "Interface", 12 => "Function",
            13 => "Variable", 14 => "Constant", 15 => "String", 16 => "Number",
            17 => "Boolean", 18 => "Array", 19 => "Object", 20 => "Key",
            21 => "Null", 22 => "EnumMember", 23 => "Struct", 24 => "Event",
            25 => "Operator", 26 => "TypeParameter",
            else => "Symbol",
        };
    }

    /// Handle LSP server notifications.
    fn handleLspNotification(self: *EventLoop, client_key: []const u8, method: []const u8, params: Value) void {
        if (std.mem.eql(u8, method, "$/progress")) {
            const language = extractLanguageFromKey(client_key);
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

            if (std.mem.eql(u8, kind, "begin")) {
                self.incrementIndexingCount(language);
                const title = json_utils.getString(value_obj, "title");
                if (token_key) |tk| {
                    if (title) |t| {
                        self.storeProgressTitle(tk, t);
                    }
                }
                const message = json_utils.getString(value_obj, "message");
                const percentage = json_utils.getInteger(value_obj, "percentage");
                if (formatProgressEcho(alloc, title, message, percentage)) |echo_cmd| {
                    self.broadcastVimEx(alloc, echo_cmd);
                }
            } else if (std.mem.eql(u8, kind, "report")) {
                const title = if (token_key) |tk| self.progress_titles.get(tk) else null;
                const message = json_utils.getString(value_obj, "message");
                const percentage = json_utils.getInteger(value_obj, "percentage");
                if (formatProgressEcho(alloc, title, message, percentage)) |echo_cmd| {
                    self.broadcastVimEx(alloc, echo_cmd);
                }
            } else if (std.mem.eql(u8, kind, "end")) {
                if (token_key) |tk| {
                    if (self.progress_titles.fetchRemove(tk)) |entry| {
                        self.allocator.free(entry.key);
                        self.allocator.free(entry.value);
                    }
                }
                self.decrementIndexingCount(language);
                if (!self.isAnyLanguageIndexing()) {
                    self.broadcastVimEx(alloc, "echo '[yac] Indexing complete'");
                    self.flushDeferredRequests();
                }
            }
        } else if (std.mem.eql(u8, method, "textDocument/publishDiagnostics")) {
            // Broadcast diagnostics to ALL connected clients
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const encoded = vim.encodeJsonRpcNotification(arena.allocator(), "diagnostics", params) catch return;
            self.broadcastRaw(encoded);
        } else {
            log.debug("LSP notification: {s}", .{method});
        }
    }

    /// Store a progress title, associating a token key with a title string.
    fn storeProgressTitle(self: *EventLoop, token_key: []const u8, title: []const u8) void {
        const key_owned = self.allocator.dupe(u8, token_key) catch return;
        const title_owned = self.allocator.dupe(u8, title) catch {
            self.allocator.free(key_owned);
            return;
        };
        self.progress_titles.put(key_owned, title_owned) catch {
            self.allocator.free(key_owned);
            self.allocator.free(title_owned);
        };
    }

    /// Flush deferred requests after LSP indexing completes.
    /// Skips requests older than deferred_ttl_ns.
    fn flushDeferredRequests(self: *EventLoop) void {
        const count = self.deferred_requests.items.len;
        if (count == 0) return;

        log.info("Flushing {d} deferred requests", .{count});

        var requests = self.deferred_requests;
        self.deferred_requests = .{};
        defer {
            for (requests.items) |req| self.allocator.free(req.raw_line);
            requests.deinit(self.allocator);
        }

        const now = std.time.nanoTimestamp();
        var dropped: usize = 0;

        for (requests.items) |req| {
            if (now - req.timestamp_ns > deferred_ttl_ns) {
                dropped += 1;
                continue;
            }
            if (self.clients.contains(req.client_id)) {
                self.handleVimLine(req.client_id, req.raw_line);
            }
        }

        if (dropped > 0) {
            log.info("Dropped {d} stale deferred requests", .{dropped});
        }
    }

    // ====================================================================
    // Send helpers — targeted to a specific client or broadcast to all
    // ====================================================================

    /// Write a newline-terminated message to a stream, ignoring errors.
    fn writeMessage(stream: std.net.Stream, data: []const u8) void {
        stream.writeAll(data) catch return;
        stream.writeAll("\n") catch return;
    }

    /// Send a JSON-RPC response to a specific Vim client.
    fn sendVimResponseTo(self: *EventLoop, cid: ClientId, alloc: Allocator, vim_id: ?u64, result: Value) void {
        const id = vim_id orelse return;
        const client = self.clients.get(cid) orelse return;
        const encoded = vim.encodeJsonRpcResponse(alloc, @intCast(id), result) catch |e| {
            log.err("Failed to encode response: {any}", .{e});
            return;
        };
        writeMessage(client.stream, encoded);
    }

    /// Send a Vim ex command to a specific client.
    fn sendVimExTo(self: *EventLoop, cid: ClientId, alloc: Allocator, command: []const u8) void {
        const client = self.clients.get(cid) orelse return;
        const encoded = vim.encodeChannelCommand(alloc, .{ .ex = .{ .command = command } }) catch return;
        defer alloc.free(encoded);
        writeMessage(client.stream, encoded);
    }

    /// Send an expr request to a specific Vim client and register a pending entry.
    fn sendVimExprTo(self: *EventLoop, cid: ClientId, alloc: Allocator, vim_id: ?u64, expr: []const u8, tag: PendingVimExpr.Tag) void {
        const client = self.clients.get(cid) orelse return;
        const id = self.next_expr_id;
        self.next_expr_id += 1;
        const encoded = vim.encodeChannelCommand(alloc, .{ .expr = .{ .expr = expr, .id = id } }) catch return;
        defer alloc.free(encoded);
        writeMessage(client.stream, encoded);
        self.pending_vim_exprs.put(id, .{ .cid = cid, .vim_id = vim_id, .tag = tag }) catch {};
    }

    /// Handle the result of a daemon→Vim expr request.
    fn handleVimExprResponse(self: *EventLoop, alloc: Allocator, pending: PendingVimExpr, result: Value) void {
        switch (pending.tag) {
            .picker_buffers => {
                const fi = self.file_index orelse return;
                const arr = switch (result) {
                    .array => |a| a.items,
                    else => &[_]Value{},
                };
                var names: std.ArrayList([]const u8) = .{};
                defer names.deinit(alloc);
                for (arr) |item| {
                    if (item == .string) names.append(alloc, item.string) catch {};
                }
                fi.setRecentFiles(names.items) catch {};
                self.sendPickerResults(pending.cid, alloc, pending.vim_id, fi.recent_files.items, "file");
            },
        }
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
            writeMessage(client_ptr.*.stream, encoded);
        }
    }

    /// Send an error response to a specific Vim client.
    fn sendVimErrorTo(self: *EventLoop, cid: ClientId, alloc: Allocator, vim_id: ?u64, message: []const u8) void {
        if (vim_id) |_| {
            var err_obj = ObjectMap.init(alloc);
            err_obj.put("error", json_utils.jsonString(message)) catch return;
            self.sendVimResponseTo(cid, alloc, vim_id, .{ .object = err_obj });
        }
    }

    /// Increment indexing count for a language.
    fn incrementIndexingCount(self: *EventLoop, language: []const u8) void {
        if (self.indexing_counts.getPtr(language)) |count| {
            count.* += 1;
        } else {
            const key = self.allocator.dupe(u8, language) catch return;
            self.indexing_counts.put(key, 1) catch {
                self.allocator.free(key);
            };
        }
    }

    /// Decrement indexing count for a language.
    fn decrementIndexingCount(self: *EventLoop, language: []const u8) void {
        if (self.indexing_counts.getPtr(language)) |count| {
            if (count.* > 0) count.* -= 1;
        }
    }

    /// Check if a specific language is currently indexing.
    fn isLanguageIndexing(self: *EventLoop, language: []const u8) bool {
        if (self.indexing_counts.get(language)) |count| {
            return count > 0;
        }
        return false;
    }

    /// Check if any language is currently indexing (for flushDeferredRequests).
    fn isAnyLanguageIndexing(self: *EventLoop) bool {
        var it = self.indexing_counts.valueIterator();
        while (it.next()) |count| {
            if (count.* > 0) return true;
        }
        return false;
    }

    /// Handle picker-specific actions returned by handlers.
    /// Returns true if the action was handled.
    fn handlePickerAction(self: *EventLoop, cid: ClientId, alloc: Allocator, vim_id: ?u64, data: Value) bool {
        const obj = switch (data) {
            .object => |o| o,
            else => return false,
        };
        const action = json_utils.getString(obj, "action") orelse return false;

        if (std.mem.eql(u8, action, "picker_init")) {
            const cwd = json_utils.getString(obj, "cwd") orelse return true;
            if (self.file_index) |fi| {
                fi.deinit();
                self.allocator.destroy(fi);
            }
            const fi = self.allocator.create(picker_mod.FileIndex) catch return true;
            fi.* = picker_mod.FileIndex.init(self.allocator);
            fi.startScan(cwd) catch {
                fi.deinit();
                self.allocator.destroy(fi);
                return true;
            };
            self.file_index = fi;
            self.sendVimExprTo(cid, alloc, vim_id,
                "map(getbufinfo({'buflisted':1}), {_, b -> b.name})",
                .picker_buffers);
            return true;
        } else if (std.mem.eql(u8, action, "picker_file_query")) {
            const query = json_utils.getString(obj, "query") orelse "";
            const fi = self.file_index orelse {
                self.sendVimResponseTo(cid, alloc, vim_id, .null);
                return true;
            };
            _ = fi.pollScan();
            if (query.len == 0) {
                self.sendPickerResults(cid, alloc, vim_id, fi.recent_files.items, "file");
            } else {
                const indices = picker_mod.filterAndSort(alloc, fi.files.items, query) catch {
                    self.sendVimResponseTo(cid, alloc, vim_id, .null);
                    return true;
                };
                var items: std.ArrayList([]const u8) = .{};
                for (indices) |idx| {
                    items.append(alloc, fi.files.items[idx]) catch {};
                }
                self.sendPickerResults(cid, alloc, vim_id, items.items, "file");
            }
            return true;
        } else if (std.mem.eql(u8, action, "picker_close")) {
            if (self.file_index) |fi| {
                fi.deinit();
                self.allocator.destroy(fi);
                self.file_index = null;
            }
            self.sendVimResponseTo(cid, alloc, vim_id, .null);
            return true;
        }
        return false;
    }

    /// Send picker results in the standard format.
    fn sendPickerResults(self: *EventLoop, cid: ClientId, alloc: Allocator, vim_id: ?u64, paths: []const []const u8, mode: []const u8) void {
        var items = std.json.Array.init(alloc);
        for (paths) |path| {
            var item = ObjectMap.init(alloc);
            item.put("label", json_utils.jsonString(path)) catch continue;
            item.put("detail", json_utils.jsonString("")) catch continue;
            item.put("file", json_utils.jsonString(path)) catch continue;
            item.put("line", json_utils.jsonInteger(0)) catch continue;
            item.put("column", json_utils.jsonInteger(0)) catch continue;
            items.append(.{ .object = item }) catch continue;
        }
        var result = ObjectMap.init(alloc);
        result.put("items", .{ .array = items }) catch {};
        result.put("mode", json_utils.jsonString(mode)) catch {};
        self.sendVimResponseTo(cid, alloc, vim_id, .{ .object = result });
    }
};

/// Extract language name from a client_key ("language\x00workspace_uri" or just "language").
fn extractLanguageFromKey(client_key: []const u8) []const u8 {
    if (std.mem.indexOf(u8, client_key, "\x00")) |pos| {
        return client_key[0..pos];
    }
    return client_key;
}

/// Check if a Vim method is a query that should be deferred during LSP indexing.
pub fn isQueryMethod(method: []const u8) bool {
    const query_methods = [_][]const u8{
        "goto_definition",
        "goto_declaration",
        "goto_type_definition",
        "goto_implementation",
        "hover",
        "completion",
        "references",
        "rename",
        "code_action",
        "document_symbols",
        "inlay_hints",
        "folding_range",
        "call_hierarchy",
        "picker_query",
    };
    for (query_methods) |m| {
        if (std.mem.eql(u8, method, m)) return true;
    }
    return false;
}

/// Format a progress echo command for Vim.
/// Returns null if no title is available (nothing useful to show).
fn formatProgressEcho(alloc: Allocator, title: ?[]const u8, message: ?[]const u8, percentage: ?i64) ?[]const u8 {
    const t = title orelse return null;

    // Escape single quotes for Vim's echo '...' syntax
    const escaped_title = escapeVimString(alloc, t) catch return null;
    const escaped_message = if (message) |m| (escapeVimString(alloc, m) catch null) else null;

    // Build: [yac] Title (N%): Message
    if (percentage) |pct| {
        if (escaped_message) |msg| {
            return std.fmt.allocPrint(alloc, "echo '[yac] {s} ({d}%): {s}'", .{ escaped_title, pct, msg }) catch null;
        }
        return std.fmt.allocPrint(alloc, "echo '[yac] {s} ({d}%)'", .{ escaped_title, pct }) catch null;
    }

    if (escaped_message) |msg| {
        return std.fmt.allocPrint(alloc, "echo '[yac] {s}: {s}'", .{ escaped_title, msg }) catch null;
    }

    return std.fmt.allocPrint(alloc, "echo '[yac] {s}'", .{escaped_title}) catch null;
}

/// Escape a string for safe use in Vim's echo '...' syntax.
/// Handles single quotes, backslashes, newlines/carriage returns, and truncates long messages.
fn escapeVimString(alloc: Allocator, input: []const u8) ![]const u8 {
    const max_len: usize = 200;
    const src = if (input.len > max_len) input[0..max_len] else input;
    const truncated = input.len > max_len;

    // Count extra bytes needed and check if any escaping is required
    var extra: usize = 0;
    var needs_escaping = truncated;
    for (src) |c| {
        switch (c) {
            '\'' => extra += 1,
            '\\' => extra += 1,
            '\n', '\r' => needs_escaping = true,
            else => {},
        }
    }
    if (extra > 0) needs_escaping = true;
    if (!needs_escaping) return src;

    const suffix = if (truncated) "..." else "";
    var result = try alloc.alloc(u8, src.len + extra + suffix.len);
    var i: usize = 0;
    for (src) |c| {
        switch (c) {
            '\'', '\\' => {
                result[i] = c;
                i += 1;
                result[i] = c;
                i += 1;
            },
            '\n', '\r' => {
                result[i] = ' ';
                i += 1;
            },
            else => {
                result[i] = c;
                i += 1;
            },
        }
    }
    @memcpy(result[i..][0..suffix.len], suffix);
    return result[0 .. i + suffix.len];
}

/// Transform a goto LSP response into a Location for Vim.
fn transformGotoResult(alloc: Allocator, result: Value, ssh_host: ?[]const u8) !Value {
    const location = switch (result) {
        .object => result,
        .array => |arr| blk: {
            if (arr.items.len == 0) break :blk Value.null;
            break :blk arr.items[0];
        },
        else => return .null,
    };

    if (location == .null) return .null;

    const loc_obj = switch (location) {
        .object => |o| o,
        else => return .null,
    };

    const uri = json_utils.getString(loc_obj, "uri") orelse
        json_utils.getString(loc_obj, "targetUri") orelse
        return .null;

    const file_path = lsp_registry_mod.uriToFilePath(uri) orelse return .null;

    const range_val = loc_obj.get("range") orelse loc_obj.get("targetSelectionRange") orelse return .null;
    const range_obj = switch (range_val) {
        .object => |o| o,
        else => return .null,
    };

    const start_val = range_obj.get("start") orelse return .null;
    const start_obj = switch (start_val) {
        .object => |o| o,
        else => return .null,
    };

    const line = json_utils.getInteger(start_obj, "line") orelse return .null;
    const column = json_utils.getInteger(start_obj, "character") orelse return .null;

    const result_path = if (ssh_host) |host|
        std.fmt.allocPrint(alloc, "scp://{s}/{s}", .{ host, file_path }) catch return .null
    else
        file_path;

    var loc = ObjectMap.init(alloc);
    try loc.put("file", json_utils.jsonString(result_path));
    try loc.put("line", json_utils.jsonInteger(line));
    try loc.put("column", json_utils.jsonInteger(column));

    return .{ .object = loc };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    log.init();
    defer log.deinit();

    // Compute socket path
    var sock_path_buf: [256]u8 = undefined;
    const socket_path = getSocketPath(&sock_path_buf);

    // Check if a daemon is already running by trying to connect
    {
        const existing = std.net.connectUnixSocket(socket_path) catch null;
        if (existing) |stream| {
            stream.close();
            log.info("Daemon already running on {s}, exiting.", .{socket_path});
            return;
        }
        // Connection failed = stale socket from a previous crash, safe to remove
        std.fs.deleteFileAbsolute(socket_path) catch {};
    }

    log.info("Binding to socket: {s}", .{socket_path});

    const address = try std.net.Address.initUnix(socket_path);
    const server = try address.listen(.{ .reuse_address = true });

    var event_loop = EventLoop.init(allocator, server);
    defer event_loop.deinit();

    event_loop.run() catch |e| {
        log.err("Event loop failed: {any}", .{e});
    };

    // Clean up socket file
    std.fs.deleteFileAbsolute(socket_path) catch {};
    log.info("lsp-bridge daemon shutdown complete", .{});
}

// ============================================================================
// Tests - import all modules to run their tests too
// ============================================================================

test {
    _ = @import("json_utils.zig");
    _ = @import("vim_protocol.zig");
    _ = @import("lsp_protocol.zig");
    _ = @import("lsp_registry.zig");
    _ = @import("lsp_client.zig");
}

test "isQueryMethod - query methods return true" {
    try std.testing.expect(isQueryMethod("goto_definition"));
    try std.testing.expect(isQueryMethod("goto_declaration"));
    try std.testing.expect(isQueryMethod("goto_type_definition"));
    try std.testing.expect(isQueryMethod("goto_implementation"));
    try std.testing.expect(isQueryMethod("hover"));
    try std.testing.expect(isQueryMethod("completion"));
    try std.testing.expect(isQueryMethod("references"));
    try std.testing.expect(isQueryMethod("rename"));
    try std.testing.expect(isQueryMethod("code_action"));
    try std.testing.expect(isQueryMethod("document_symbols"));
    try std.testing.expect(isQueryMethod("inlay_hints"));
    try std.testing.expect(isQueryMethod("folding_range"));
    try std.testing.expect(isQueryMethod("call_hierarchy"));
}

test "isQueryMethod - non-query methods return false" {
    try std.testing.expect(!isQueryMethod("file_open"));
    try std.testing.expect(!isQueryMethod("did_change"));
    try std.testing.expect(!isQueryMethod("did_save"));
    try std.testing.expect(!isQueryMethod("did_close"));
    try std.testing.expect(!isQueryMethod("will_save"));
    try std.testing.expect(!isQueryMethod("diagnostics"));
    try std.testing.expect(!isQueryMethod("execute_command"));
    try std.testing.expect(!isQueryMethod("unknown_method"));
}

test {
    _ = @import("picker.zig");
}
