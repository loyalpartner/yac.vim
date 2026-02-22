const std = @import("std");
const json_utils = @import("json_utils.zig");
const vim = @import("vim_protocol.zig");
const lsp_registry_mod = @import("lsp_registry.zig");
const handlers_mod = @import("handlers.zig");
const picker_mod = @import("picker.zig");
const log = @import("log.zig");
const lsp_transform = @import("lsp_transform.zig");
const vim_out = @import("vim.zig");
const clients_mod = @import("clients.zig");
const requests_mod = @import("requests.zig");
const lsp_mod = @import("lsp.zig");
const progress_mod = @import("progress.zig");

const Allocator = std.mem.Allocator;
const Value = json_utils.Value;
const ObjectMap = json_utils.ObjectMap;

// ============================================================================
// Client ID and VimClient — each connected Vim instance
// ============================================================================

const ClientId = clients_mod.ClientId;

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

const PendingVimExpr = requests_mod.PendingVimExpr;

const IDLE_TIMEOUT_NS: i128 = 60 * std.time.ns_per_s;

const EventLoop = struct {
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

    const DeferredRequest = lsp_mod.Lsp.DeferredRequest;

    fn init(allocator: Allocator, listener: std.net.Server) EventLoop {
        return .{
            .allocator = allocator,
            .lsp = lsp_mod.Lsp.init(allocator),
            .listener = listener,
            .clients = clients_mod.Clients.init(allocator),
            .requests = requests_mod.Requests.init(allocator),
            .progress = progress_mod.Progress.init(allocator),
            .idle_deadline = std.time.nanoTimestamp(),
            .picker = picker_mod.Picker.init(allocator),
        };
    }

    fn deinit(self: *EventLoop) void {
        self.lsp.deinit();
        self.requests.deinit();
        self.clients.deinit();
        self.progress.deinit();
        self.picker.deinit();
        self.listener.deinit();
    }

    const PollSetup = struct {
        client_count: usize,
        picker_fd_index: ?usize,
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

        // fd[N+M+1] = picker fd/find stdout (if active)
        const picker_fd_index: ?usize = if (self.picker.getStdoutFd()) |fd| idx: {
            const idx = poll_fds.items.len;
            try poll_fds.append(self.allocator, .{
                .fd = fd,
                .events = std.posix.POLL.IN,
                .revents = 0,
            });
            break :idx idx;
        } else null;

        return .{ .client_count = client_count, .picker_fd_index = picker_fd_index };
    }

    fn pollTimeout(self: *EventLoop) i32 {
        const deadline = self.idle_deadline orelse return 100;
        const remaining_ns = deadline - std.time.nanoTimestamp();
        if (remaining_ns <= 0) return 0;
        return @intCast(@min(@divTrunc(remaining_ns, std.time.ns_per_ms), 100));
    }

    fn shouldExitIdle(self: *EventLoop) bool {
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

    fn handlePickerFd(self: *EventLoop, poll_fds: []std.posix.pollfd, picker_fd_index: ?usize) void {
        if (picker_fd_index) |pfi| {
            if (poll_fds[pfi].revents & (std.posix.POLL.IN | std.posix.POLL.HUP) != 0) {
                self.picker.pollScan();
            }
        }
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

            const poll_setup = try self.buildPollFds(&poll_fds, &poll_client_keys, &client_id_order);

            const ready = std.posix.poll(poll_fds.items, self.pollTimeout()) catch |e| {
                log.err("poll failed: {any}", .{e});
                continue;
            };

            if (ready == 0) {
                if (self.shouldExitIdle()) break;
                continue;
            }

            self.handleListener(poll_fds.items);
            self.handleClientFds(poll_fds.items, poll_setup.client_count, client_id_order.items, buf[0..]);
            self.handleLspFds(poll_fds.items, poll_setup.client_count, poll_client_keys.items);
            self.handlePickerFd(poll_fds.items, poll_setup.picker_fd_index);
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
                log.debug("Vim[{d}] request [{d}]: {s}", .{ cid, r.id, r.method });
                self.handleVimRequest(cid, alloc, r.id, r.method, r.params, trimmed);
            },
            .notification => |n| {
                log.debug("Vim[{d}] notification: {s}", .{ cid, n.method });
                self.handleVimRequest(cid, alloc, null, n.method, n.params, trimmed);
            },
            .response => |r| {
                log.debug("Vim[{d}] response [{d}]", .{ cid, r.id });
                // Responses to Vim "call" commands (expr responses are intercepted above)
            },
        }
    }

    /// Handle a Vim request or notification.
    fn handleVimRequest(self: *EventLoop, cid: ClientId, alloc: Allocator, vim_id: ?u64, method: []const u8, params: Value, raw_line: []const u8) void {
        // Defer query methods while the relevant LSP server is indexing
        const request_language: ?[]const u8 = if (lsp_mod.isQueryMethod(method)) blk: {
            const obj = switch (params) { .object => |o| o, else => break :blk null };
            const file = json_utils.getString(obj, "file") orelse break :blk null;
            break :blk lsp_registry_mod.LspRegistry.detectLanguage(lsp_registry_mod.extractRealPath(file));
        } else null;
        if (vim_id != null and request_language != null and self.lsp.isLanguageIndexing(request_language.?)) {
            if (self.lsp.enqueueDeferred(cid, raw_line)) {
                log.info("Deferred {s} request (LSP indexing in progress)", .{method});
                self.sendVimExTo(cid, alloc, "echo '[yac] LSP indexing, request queued...'");
            }
            return;
        }

        const client = self.clients.get(cid) orelse return;

        var ctx = handlers_mod.HandlerContext{
            .allocator = alloc,
            .registry = &self.lsp.registry,
            .client_stream = client.stream,
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
                    .respond_results => |r| self.sendVimResponseTo(cid, alloc, vim_id, picker_mod.buildPickerResults(alloc, r.paths, r.mode)),
                    .query_buffers => self.sendVimExprTo(cid, alloc, vim_id,
                        "map(getbufinfo({'buflisted':1}), {_, b -> b.name})",
                        .picker_buffers),
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
                        self.sendVimExTo(cid, alloc, "echo '[yac] LSP initializing, request queued...'");
                    } else {
                        self.sendVimResponseTo(cid, alloc, vim_id, .null);
                    }
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

        self.requests.addLsp(lsp_request_id, .{
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
                            self.lsp.registry.handleInitializeResponse(client_key) catch |e| {
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
                            log.err("LSP error for request {d}: {any}", .{ resp.id, err_val });
                            self.sendVimResponseTo(pending.client_id, arena.allocator(), pending.vim_request_id, .null);
                        } else {
                            const transformed = lsp_transform.transformLspResult(
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
        const lsp_client = self.lsp.registry.getClient(client_key) orelse return;

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
            const client = self.lsp.registry.getClient(client_key) orelse break :blk null;
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

        self.lsp.registry.removeClient(client_key);
    }

    /// Handle LSP server notifications.
    fn handleLspNotification(self: *EventLoop, client_key: []const u8, method: []const u8, params: Value) void {
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
                if (lsp_transform.formatProgressEcho(alloc, title, message, percentage)) |echo_cmd| {
                    self.broadcastVimEx(alloc, echo_cmd);
                }
            } else if (std.mem.eql(u8, kind, "report")) {
                const title = if (token_key) |tk| self.progress.getTitle(tk) else null;
                if (lsp_transform.formatProgressEcho(alloc, title, message, percentage)) |echo_cmd| {
                    self.broadcastVimEx(alloc, echo_cmd);
                }
            } else if (std.mem.eql(u8, kind, "end")) {
                if (token_key) |tk| self.progress.removeTitle(tk);
                self.lsp.decrementIndexingCount(language);
                if (!self.lsp.isAnyLanguageIndexing()) {
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

    /// Flush deferred requests after LSP indexing completes.
    fn flushDeferredRequests(self: *EventLoop) void {
        var requests = self.lsp.takeDeferredRequests();
        defer {
            for (requests.items) |req| self.allocator.free(req.raw_line);
            requests.deinit(self.allocator);
        }

        for (requests.items) |req| {
            if (self.clients.contains(req.client_id)) {
                self.handleVimLine(req.client_id, req.raw_line);
            }
        }
    }

    // ====================================================================
    // Send helpers — targeted to a specific client or broadcast to all
    // ====================================================================

    /// Send a JSON-RPC response to a specific Vim client.
    fn sendVimResponseTo(self: *EventLoop, cid: ClientId, alloc: Allocator, vim_id: ?u64, result: Value) void {
        const id = vim_id orelse return;
        const client = self.clients.get(cid) orelse return;
        vim_out.sendVimResponse(alloc, client.stream, id, result);
    }

    /// Send a Vim ex command to a specific client.
    fn sendVimExTo(self: *EventLoop, cid: ClientId, alloc: Allocator, command: []const u8) void {
        const client = self.clients.get(cid) orelse return;
        vim_out.sendVimEx(alloc, client.stream, command);
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
        vim_out.writeMessage(client.stream, encoded);
    }

    /// Handle the result of a daemon→Vim expr request.
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
            vim_out.writeMessage(client_ptr.*.stream, encoded);
        }
    }

    /// Send an error response to a specific Vim client.
    fn sendVimErrorTo(self: *EventLoop, cid: ClientId, alloc: Allocator, vim_id: ?u64, message: []const u8) void {
        const client = self.clients.get(cid) orelse return;
        vim_out.sendVimError(alloc, client.stream, vim_id, message);
    }

};

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
    if (std.net.connectUnixSocket(socket_path) catch null) |stream| {
        stream.close();
        log.info("Daemon already running on {s}, exiting.", .{socket_path});
        return;
    }
    // Connection failed = stale socket from a previous crash, safe to remove
    std.fs.deleteFileAbsolute(socket_path) catch {};

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
    _ = @import("lsp.zig");
    _ = @import("picker.zig");
}
