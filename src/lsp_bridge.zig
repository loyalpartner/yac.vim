const std = @import("std");
const json_utils = @import("json_utils.zig");
const rpc = @import("rpc.zig");
const vim_transport_mod = @import("vim_transport.zig");
const lsp_mod = @import("lsp/lsp.zig");
const lsp_transform = @import("lsp/transform.zig");
const lsp_protocol = @import("lsp/protocol.zig");
const lsp_client_mod = @import("lsp/client.zig");
const queue_mod = @import("queue.zig");
const requests_mod = @import("requests.zig");
const clients_mod = @import("clients.zig");
const vim_expr_tracker_mod = @import("vim_expr_tracker.zig");
const log = @import("log.zig");

const LspPendingRequests = requests_mod.LspPendingRequests;

const Allocator = std.mem.Allocator;
const Value = json_utils.Value;
const ClientId = clients_mod.ClientId;

// ============================================================================
// LSP notification payload types
// ============================================================================

const ProgressValue = struct {
    kind: []const u8 = "",
    message: ?[]const u8 = null,
    title: ?[]const u8 = null,
    percentage: ?i64 = null,
};

/// Resolve a progress token (string | integer) to a string key.
fn resolveTokenKey(alloc: Allocator, params_obj: json_utils.ObjectMap) ?[]const u8 {
    const token_val = params_obj.get("token") orelse return null;
    return switch (token_val) {
        .string => |s| s,
        .integer => |i| std.fmt.allocPrint(alloc, "{d}", .{i}) catch null,
        else => null,
    };
}

// ============================================================================
// LspBridge
// ============================================================================

/// Persistent LSP bridge: owns pending request tracking and processes LSP server messages.
pub const LspBridge = struct {
    allocator: Allocator,
    lsp: *lsp_mod.Lsp,
    lsp_pending: LspPendingRequests,
    in_general: *queue_mod.InQueue,
    in_ts: *queue_mod.InQueue,
    out_queue: *queue_mod.OutQueue,
    clients: *clients_mod.Clients,
    expr_tracker: *vim_expr_tracker_mod.VimExprTracker,

    pub fn init(
        allocator: Allocator,
        lsp: *lsp_mod.Lsp,
        in_general: *queue_mod.InQueue,
        in_ts: *queue_mod.InQueue,
        out_queue: *queue_mod.OutQueue,
        clients: *clients_mod.Clients,
        expr_tracker: *vim_expr_tracker_mod.VimExprTracker,
    ) LspBridge {
        return .{
            .allocator = allocator,
            .lsp = lsp,
            .lsp_pending = LspPendingRequests.init(allocator),
            .in_general = in_general,
            .in_ts = in_ts,
            .out_queue = out_queue,
            .clients = clients,
            .expr_tracker = expr_tracker,
        };
    }

    pub fn deinit(self: *LspBridge) void {
        self.lsp_pending.deinit();
    }

    /// Construct a VimTransport for sending messages to Vim clients.
    fn transport(self: *LspBridge) vim_transport_mod.VimTransport {
        return .{
            .allocator = self.allocator,
            .out_queue = self.out_queue,
            .clients = self.clients,
            .expr_tracker = self.expr_tracker,
        };
    }

    // ----------------------------------------------------------------
    // Public entry point — called by EventLoop after reading stdout
    // ----------------------------------------------------------------

    /// Process raw bytes already read from an LSP server's stdout.
    /// EventLoop owns the read; we do framing + dispatch only.
    pub fn feedOutput(self: *LspBridge, client_key: []const u8, data: []const u8) void {
        const client = self.lsp.registry.getClient(client_key) orelse return;

        var raw_messages = client.framer.feedData(self.allocator, data) catch |e| {
            log.err("LSP framing error for {s}: {any}", .{ client_key, e });
            return;
        };
        defer {
            for (raw_messages.items) |msg| self.allocator.free(msg);
            raw_messages.deinit(self.allocator);
        }

        // Arena for JSON parsing — lives until all messages are dispatched
        var parse_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer parse_arena.deinit();
        const parse_alloc = parse_arena.allocator();

        for (raw_messages.items) |raw_msg| {
            const parsed = json_utils.parse(parse_alloc, raw_msg) catch continue;
            const msg = lsp_protocol.Message.fromValue(parse_alloc, parsed.value) orelse continue;

            // Remove pending request tracking for responses
            switch (msg) {
                .response => |resp| {
                    if (resp.id.asU32()) |int_id| _ = client.pending_requests.remove(int_id);
                },
                else => {},
            }

            switch (msg) {
                .response => |resp| self.handleResponse(client_key, resp),
                .notification => |n| self.handleNotification(client_key, n.method, n.params),
                .request => |req| self.handleServerRequest(client_key, req),
            }
        }
    }

    // ----------------------------------------------------------------
    // Responses
    // ----------------------------------------------------------------

    const LspResponse = lsp_protocol.Response;

    fn handleResponse(self: *LspBridge, client_key: []const u8, resp: LspResponse) void {
        const rid = resp.id.asU32() orelse {
            log.debug("Unmatched LSP response id={any}", .{resp.id});
            return;
        };

        if (self.isInitializeResponse(client_key, rid, resp.result)) return;
        self.routeToVim(rid, resp);
    }

    fn isInitializeResponse(self: *LspBridge, client_key: []const u8, rid: u32, result: Value) bool {
        const init_id = self.lsp.registry.getInitRequestId(client_key) orelse return false;
        if (rid != init_id) return false;

        self.lsp.registry.handleInitializeResponse(client_key, result) catch |e| {
            log.err("Failed to handle init response: {any}", .{e});
        };
        if (!self.lsp.isAnyLanguageIndexing()) self.flushDeferredRequests();
        return true;
    }

    fn routeToVim(self: *LspBridge, rid: u32, resp: LspResponse) void {
        const pending = self.lsp_pending.remove(rid) orelse {
            log.debug("Unmatched LSP response id={any}", .{resp.id});
            return;
        };
        defer pending.deinit(self.allocator);

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        if (resp.err) |err_val| {
            const err_str = json_utils.stringifyAlloc(alloc, err_val) catch "?";
            log.err("LSP error for request {any} ({s}): {s}", .{ resp.id, pending.method, err_str });
            self.transport().sendResponseTo(pending.client_id, alloc, pending.vim_request_id, .null);
            return;
        }

        const tctx = self.transformContext(pending.lsp_client_key);
        const transformed = pending.transform(alloc, resp.result, tctx);
        log.debug("LSP response [{any}]: {s} -> Vim[{d}] (null={any})", .{ resp.id, pending.method, pending.client_id, transformed == .null });
        self.transport().sendResponseTo(pending.client_id, alloc, pending.vim_request_id, transformed);
    }

    fn transformContext(self: *LspBridge, client_key: ?[]const u8) lsp_transform.TransformContext {
        return .{
            .server_caps = if (client_key) |key|
                if (self.lsp.registry.server_capabilities.get(key)) |parsed| parsed.value else null
            else
                null,
        };
    }

    // ----------------------------------------------------------------
    // Server-to-client requests
    // ----------------------------------------------------------------

    const LspRequest = lsp_protocol.Request;

    /// Known server request methods that we acknowledge silently.
    const silent_server_requests: []const []const u8 = &.{
        "window/workDoneProgress/create",
        "client/registerCapability",
        "client/unregisterCapability",
    };

    fn handleServerRequest(self: *LspBridge, client_key: []const u8, req: LspRequest) void {
        const lsp_client = self.lsp.registry.getClient(client_key) orelse return;

        if (std.mem.eql(u8, req.method, "workspace/applyEdit")) {
            self.handleApplyEdit(client_key, lsp_client, req);
            return;
        }

        // Log unknown requests, acknowledge all with null
        if (!isSilentRequest(req.method)) {
            log.debug("Unknown server request: {s} (id={any})", .{ req.method, req.id });
        }
        lsp_client.send(.{ .response = .{ .id = req.id, .result = .null } }) catch |e| {
            log.err("Failed to respond to {s}: {any}", .{ req.method, e });
        };
    }

    fn handleApplyEdit(self: *LspBridge, client_key: []const u8, lsp_client: *lsp_client_mod.LspClient, req: LspRequest) void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        const result = json_utils.structToValue(alloc, .{ .applied = true }) catch .null;
        lsp_client.send(.{ .response = .{ .id = req.id, .result = result } }) catch |e| {
            log.err("Failed to respond to workspace/applyEdit: {any}", .{e});
        };

        const workspace_uri = lsp_mod.extractWorkspaceFromKey(client_key);
        const encoded = (rpc.Message{ .notification = .{ .method = "applyEdit", .params = req.params } }).serialize(alloc) catch return;
        self.transport().sendToWorkspace(workspace_uri, encoded);
    }

    fn isSilentRequest(method: []const u8) bool {
        for (silent_server_requests) |m| {
            if (std.mem.eql(u8, method, m)) return true;
        }
        return false;
    }

    // ----------------------------------------------------------------
    // Notifications
    // ----------------------------------------------------------------

    fn handleNotification(self: *LspBridge, client_key: []const u8, method: []const u8, params: Value) void {
        if (std.mem.eql(u8, method, "$/progress")) {
            self.handleProgress(client_key, params);
        } else if (std.mem.eql(u8, method, "textDocument/publishDiagnostics")) {
            self.forwardDiagnostics(client_key, params);
        } else {
            log.debug("LSP notification: {s}", .{method});
        }
    }

    fn handleProgress(self: *LspBridge, client_key: []const u8, params: Value) void {
        const language = lsp_mod.extractLanguageFromKey(client_key);
        const workspace_uri = lsp_mod.extractWorkspaceFromKey(client_key);

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        const params_obj = json_utils.asObject(params) orelse return;
        const pv = json_utils.parseTyped(ProgressValue, alloc, params_obj.get("value") orelse return) orelse return;
        if (pv.kind.len == 0) return;

        const token = resolveTokenKey(alloc, params_obj);

        if (std.mem.eql(u8, pv.kind, "begin")) {
            self.lsp.incrementIndexingCount(language);
            if (token) |tk| if (pv.title) |t| self.lsp.progress.storeTitle(tk, t);
            self.sendProgressToast(workspace_uri, alloc, pv.title, pv.message, pv.percentage);
        } else if (std.mem.eql(u8, pv.kind, "report")) {
            const title = if (token) |tk| self.lsp.progress.getTitle(tk) else null;
            self.sendProgressToast(workspace_uri, alloc, title, pv.message, pv.percentage);
        } else if (std.mem.eql(u8, pv.kind, "end")) {
            if (token) |tk| self.lsp.progress.removeTitle(tk);
            self.lsp.decrementIndexingCount(language);
            if (!self.lsp.isAnyLanguageIndexing()) {
                if (lsp_transform.formatToastCmd(alloc, "[yac] Indexing complete", null)) |cmd|
                    self.transport().sendExToWorkspace(workspace_uri, alloc, cmd);
                self.flushDeferredRequests();
            }
        }
    }

    fn sendProgressToast(self: *LspBridge, workspace_uri: ?[]const u8, alloc: Allocator, title: ?[]const u8, message: ?[]const u8, percentage: ?i64) void {
        if (lsp_transform.formatProgressToast(alloc, title, message, percentage)) |cmd|
            self.transport().sendExToWorkspace(workspace_uri, alloc, cmd);
    }

    fn forwardDiagnostics(self: *LspBridge, client_key: []const u8, params: Value) void {
        const workspace_uri = lsp_mod.extractWorkspaceFromKey(client_key);
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const encoded = (rpc.Message{ .notification = .{ .method = "diagnostics", .params = params } }).serialize(arena.allocator()) catch return;
        self.transport().sendToWorkspace(workspace_uri, encoded);
    }

    // ----------------------------------------------------------------
    // Server death
    // ----------------------------------------------------------------

    pub fn handleDeath(self: *LspBridge, client_key: []const u8) void {
        log.err("LSP server died: {s}", .{client_key});

        const workspace_uri = lsp_mod.extractWorkspaceFromKey(client_key);

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        const stderr_snippet = readStderr(self.lsp.registry.getClient(client_key));
        const crash_msg = if (stderr_snippet) |msg|
            std.fmt.allocPrint(alloc, "[yac] LSP server crashed: {s}", .{msg}) catch return
        else
            "[yac] LSP server crashed (no stderr output)";

        if (lsp_transform.formatToastCmd(alloc, crash_msg, "ErrorMsg")) |cmd|
            self.transport().sendExToWorkspace(workspace_uri, alloc, cmd);

        self.lsp.registry.removeClient(client_key);
    }

    fn readStderr(client: ?*lsp_client_mod.LspClient) ?[]const u8 {
        const c = client orelse return null;
        // Try to capture any final stderr output into the client buffer.
        if (c.child.stderr) |f| {
            var buf: [4096]u8 = undefined;
            const n = f.read(&buf) catch 0;
            if (n > 0) c.appendStderr(buf[0..n]);
        }
        if (c.last_stderr_len > 0) {
            log.err("LSP stderr: {s}", .{c.last_stderr[0..c.last_stderr_len]});
            return c.last_stderr[0..c.last_stderr_len];
        }
        return null;
    }

    // ----------------------------------------------------------------
    // Pending request tracking (moved from EventLoop)
    // ----------------------------------------------------------------

    /// Track a pending LSP request and cancel older in-flight requests of the same type.
    pub fn trackPendingRequest(self: *LspBridge, lsp_request_id: u32, cid: ClientId, vim_id: ?u64, method: []const u8, params: Value, client_key: ?[]const u8, transform_fn: lsp_transform.TransformFn) void {
        // Cancel older in-flight requests of the same method+client (e.g. completion)
        if (client_key) |key| {
            var cancelled = self.lsp_pending.cancelByMethodAndClientKey(method, key);
            defer cancelled.deinit();
            if (cancelled.lsp_ids.items.len > 0) {
                if (self.lsp.registry.getClient(key)) |lsp_client| {
                    for (cancelled.lsp_ids.items) |old_id| {
                        lsp_client.cancelRequest(old_id) catch |e| {
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

        const file = json_utils.getStringField(params, "file");
        self.lsp_pending.track(lsp_request_id, cid, vim_id, method, file, client_key, transform_fn);
    }

    /// Remove all pending LSP requests and deferred requests for a disconnected client.
    pub fn removeForClient(self: *LspBridge, cid: ClientId) void {
        var to_remove: std.ArrayList(u32) = .{};
        defer to_remove.deinit(self.allocator);

        var pit = self.lsp_pending.iterator();
        while (pit.next()) |entry| {
            if (entry.value_ptr.client_id == cid) {
                to_remove.append(self.allocator, entry.key_ptr.*) catch {};
            }
        }
        for (to_remove.items) |req_id| {
            if (self.lsp_pending.remove(req_id)) |pending| {
                pending.deinit(self.allocator);
            }
        }

        // Remove deferred requests for this client
        self.lsp.removeDeferredForClient(cid);
    }

    // ----------------------------------------------------------------
    // Deferred request flush
    // ----------------------------------------------------------------

    /// After LSP indexing completes, re-route queued requests back to work queues.
    fn flushDeferredRequests(self: *LspBridge) void {
        var requests = self.lsp.takeDeferredRequests();
        defer {
            for (requests.items) |req| self.allocator.free(req.raw_line);
            requests.deinit(self.allocator);
        }

        for (requests.items) |req| {
            const client = self.clients.get(req.client_id) orelse continue;
            const raw_copy = self.allocator.dupe(u8, req.raw_line) catch continue;
            const item = queue_mod.WorkItem{
                .client_id = req.client_id,
                .client_stream = client.stream,
                .raw_line = raw_copy,
            };
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
