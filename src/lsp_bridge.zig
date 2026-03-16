const std = @import("std");
const json_utils = @import("json_utils.zig");
const rpc = @import("rpc.zig");
const vim_transport_mod = @import("vim_transport.zig");
const lsp_mod = @import("lsp/lsp.zig");
const lsp_transform = @import("lsp/transform.zig");
const lsp_protocol = @import("lsp/protocol.zig");
const progress_mod = @import("progress.zig");
const queue_mod = @import("queue.zig");
const log = @import("log.zig");

const Allocator = std.mem.Allocator;
const Value = json_utils.Value;

/// Lightweight context for LSP server message processing.
/// Constructed on the fly from EventLoop fields — zero-cost (stack pointers only).
pub const LspBridge = struct {
    allocator: Allocator,
    lsp: *lsp_mod.Lsp,
    progress: *progress_mod.Progress,
    in_general: *queue_mod.InQueue,
    in_ts: *queue_mod.InQueue,
    transport: vim_transport_mod.VimTransport,

    /// Handle LSP fd poll events — iterate ready fds and dispatch.
    pub fn handleFds(
        self: LspBridge,
        poll_fds: []std.posix.pollfd,
        client_count: usize,
        poll_client_keys: []const []const u8,
    ) void {
        const lsp_end = 1 + client_count + poll_client_keys.len;
        for (poll_fds[1 + client_count .. lsp_end], 0..) |pfd, i| {
            if (pfd.revents & std.posix.POLL.IN != 0) {
                self.processOutput(poll_client_keys[i]);
            }
            if (pfd.revents & (std.posix.POLL.HUP | std.posix.POLL.ERR) != 0) {
                self.handleDeath(poll_client_keys[i]);
            }
        }
    }

    fn processOutput(self: LspBridge, client_key: []const u8) void {
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
                    const rid = resp.id.asU32() orelse {
                        log.debug("Unmatched LSP response id={any}", .{resp.id});
                        continue;
                    };

                    // Check if this is an initialize response
                    if (self.lsp.registry.getInitRequestId(client_key)) |init_id| {
                        if (rid == init_id) {
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
                    if (self.transport.requests.removeLsp(rid)) |pending| {
                        defer pending.deinit(self.allocator);

                        var arena = std.heap.ArenaAllocator.init(self.allocator);
                        defer arena.deinit();

                        if (resp.err) |err_val| {
                            const err_str = json_utils.stringifyAlloc(arena.allocator(), err_val) catch "?";
                            log.err("LSP error for request {any} ({s}): {s}", .{ resp.id, pending.method, err_str });
                            self.transport.sendResponseTo(pending.client_id, arena.allocator(), pending.vim_request_id, .null);
                        } else {
                            const tctx = lsp_transform.TransformContext{
                                .server_caps = if (pending.lsp_client_key) |key|
                                    if (self.lsp.registry.server_capabilities.get(key)) |parsed| parsed.value else null
                                else
                                    null,
                            };
                            const transformed = pending.transform(arena.allocator(), resp.result, tctx);
                            log.debug("LSP response [{any}]: {s} -> Vim[{d}] (null={any})", .{ resp.id, pending.method, pending.client_id, transformed == .null });
                            self.transport.sendResponseTo(pending.client_id, arena.allocator(), pending.vim_request_id, transformed);
                        }
                    } else {
                        log.debug("Unmatched LSP response id={any}", .{resp.id});
                    }
                },
                .notification => |notif| {
                    self.handleNotification(client_key, notif.method, notif.params);
                },
                .server_request => |req| {
                    self.handleServerRequest(client_key, req.id, req.method, req.params);
                },
            }
        }
    }

    /// Handle a server-to-client request (e.g. workspace/applyEdit).
    fn handleServerRequest(self: LspBridge, client_key: []const u8, id: lsp_protocol.RequestId, method: []const u8, params: Value) void {
        const lsp_client = self.lsp.registry.getClient(client_key) orelse return;

        if (std.mem.eql(u8, method, "workspace/applyEdit")) {
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();

            const ApplyEditResult = struct { applied: bool };
            const result_value: Value = json_utils.structToValue(arena.allocator(), ApplyEditResult{ .applied = true }) catch .null;
            lsp_client.sendResponse(id, result_value) catch |e| {
                log.err("Failed to respond to workspace/applyEdit: {any}", .{e});
            };

            // Forward the edit to subscribed Vim clients
            const workspace_uri = lsp_mod.extractWorkspaceFromKey(client_key);
            const encoded = (rpc.Message{ .notification = .{ .method = "applyEdit", .params = params } }).serialize(arena.allocator()) catch return;
            self.transport.sendToWorkspace(workspace_uri, encoded);
            return;
        }

        // All other server requests: acknowledge with null
        if (!std.mem.eql(u8, method, "window/workDoneProgress/create") and
            !std.mem.eql(u8, method, "client/registerCapability") and
            !std.mem.eql(u8, method, "client/unregisterCapability"))
        {
            log.debug("Unknown server request: {s} (id={any})", .{ method, id });
        }
        const null_value: Value = .null;
        lsp_client.sendResponse(id, null_value) catch |e| {
            log.err("Failed to respond to {s}: {any}", .{ method, e });
        };
    }

    fn handleDeath(self: LspBridge, client_key: []const u8) void {
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
            self.transport.sendExToWorkspace(workspace_uri, alloc, cmd);

        self.lsp.registry.removeClient(client_key);
    }

    /// Handle LSP server notifications.
    fn handleNotification(self: LspBridge, client_key: []const u8, method: []const u8, params: Value) void {
        const workspace_uri = lsp_mod.extractWorkspaceFromKey(client_key);

        if (std.mem.eql(u8, method, "$/progress")) {
            const language = lsp_mod.extractLanguageFromKey(client_key);

            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const alloc = arena.allocator();

            const ProgressValue = struct {
                kind: []const u8 = "",
                message: ?[]const u8 = null,
                title: ?[]const u8 = null,
                percentage: ?i64 = null,
            };

            const params_obj = json_utils.asObject(params) orelse return;
            const value_val = params_obj.get("value") orelse return;
            const pv = json_utils.parseTyped(ProgressValue, alloc, value_val) orelse return;
            if (pv.kind.len == 0) return;

            // token can be string or integer — resolve to string for progress title tracking
            const token_key: ?[]const u8 = blk: {
                const token_val = params_obj.get("token") orelse break :blk null;
                switch (token_val) {
                    .string => |s| break :blk s,
                    .integer => |i| break :blk std.fmt.allocPrint(alloc, "{d}", .{i}) catch null,
                    else => break :blk null,
                }
            };

            if (std.mem.eql(u8, pv.kind, "begin")) {
                self.lsp.incrementIndexingCount(language);
                if (token_key) |tk| if (pv.title) |t| self.progress.storeTitle(tk, t);
                if (lsp_transform.formatProgressToast(alloc, pv.title, pv.message, pv.percentage)) |echo_cmd| {
                    self.transport.sendExToWorkspace(workspace_uri, alloc, echo_cmd);
                }
            } else if (std.mem.eql(u8, pv.kind, "report")) {
                const title = if (token_key) |tk| self.progress.getTitle(tk) else null;
                if (lsp_transform.formatProgressToast(alloc, title, pv.message, pv.percentage)) |echo_cmd| {
                    self.transport.sendExToWorkspace(workspace_uri, alloc, echo_cmd);
                }
            } else if (std.mem.eql(u8, pv.kind, "end")) {
                if (token_key) |tk| self.progress.removeTitle(tk);
                self.lsp.decrementIndexingCount(language);
                if (!self.lsp.isAnyLanguageIndexing()) {
                    if (lsp_transform.formatToastCmd(alloc, "[yac] Indexing complete", null)) |cmd|
                        self.transport.sendExToWorkspace(workspace_uri, alloc, cmd);
                    self.flushDeferredRequests();
                }
            }
        } else if (std.mem.eql(u8, method, "textDocument/publishDiagnostics")) {
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const encoded = (rpc.Message{ .notification = .{ .method = "diagnostics", .params = params } }).serialize(arena.allocator()) catch return;
            self.transport.sendToWorkspace(workspace_uri, encoded);
        } else {
            log.debug("LSP notification: {s}", .{method});
        }
    }

    /// Flush deferred requests after LSP indexing completes.
    /// Re-routes each deferred line back to the appropriate work queue.
    fn flushDeferredRequests(self: LspBridge) void {
        var requests = self.lsp.takeDeferredRequests();
        defer {
            for (requests.items) |req| self.allocator.free(req.raw_line);
            requests.deinit(self.allocator);
        }

        for (requests.items) |req| {
            const client = self.transport.clients.get(req.client_id) orelse continue;
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
};
