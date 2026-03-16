const std = @import("std");
const json_utils = @import("json_utils.zig");
const rpc = @import("rpc.zig");
const vim_transport_mod = @import("vim_transport.zig");
const lsp_mod = @import("lsp/lsp.zig");
const lsp_transform = @import("lsp/transform.zig");
const lsp_protocol = @import("lsp/protocol.zig");
const lsp_client_mod = @import("lsp/client.zig");
const progress_mod = @import("progress.zig");
const queue_mod = @import("queue.zig");
const requests_mod = @import("requests.zig");
const log = @import("log.zig");

const Allocator = std.mem.Allocator;
const Value = json_utils.Value;

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

/// Lightweight context for LSP server message processing.
/// Constructed on the fly from EventLoop fields — zero-cost (stack pointers only).
pub const LspBridge = struct {
    allocator: Allocator,
    lsp: *lsp_mod.Lsp,
    progress: *progress_mod.Progress,
    in_general: *queue_mod.InQueue,
    in_ts: *queue_mod.InQueue,
    transport: vim_transport_mod.VimTransport,

    // ----------------------------------------------------------------
    // Public entry point
    // ----------------------------------------------------------------

    /// Handle LSP fd poll events — iterate ready fds and dispatch.
    pub fn handleFds(
        self: LspBridge,
        poll_fds: []std.posix.pollfd,
        client_count: usize,
        poll_client_keys: []const []const u8,
    ) void {
        const lsp_start = 1 + client_count;
        for (poll_fds[lsp_start .. lsp_start + poll_client_keys.len], poll_client_keys) |pfd, key| {
            if (pfd.revents & std.posix.POLL.IN != 0) self.processOutput(key);
            if (pfd.revents & (std.posix.POLL.HUP | std.posix.POLL.ERR) != 0) self.handleDeath(key);
        }
    }

    // ----------------------------------------------------------------
    // Message reading & dispatch
    // ----------------------------------------------------------------

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
                .response => |resp| self.handleResponse(client_key, resp),
                .notification => |n| self.handleNotification(client_key, n.method, n.params),
                .server_request => |req| self.handleServerRequest(client_key, req),
            }
        }
    }

    // ----------------------------------------------------------------
    // Responses
    // ----------------------------------------------------------------

    const LspResponse = lsp_client_mod.LspMessage.Response;

    fn handleResponse(self: LspBridge, client_key: []const u8, resp: LspResponse) void {
        const rid = resp.id.asU32() orelse {
            log.debug("Unmatched LSP response id={any}", .{resp.id});
            return;
        };

        if (self.isInitializeResponse(client_key, rid, resp.result)) return;
        self.routeToVim(rid, resp);
    }

    fn isInitializeResponse(self: LspBridge, client_key: []const u8, rid: u32, result: Value) bool {
        const init_id = self.lsp.registry.getInitRequestId(client_key) orelse return false;
        if (rid != init_id) return false;

        self.lsp.registry.handleInitializeResponse(client_key, result) catch |e| {
            log.err("Failed to handle init response: {any}", .{e});
        };
        if (!self.lsp.isAnyLanguageIndexing()) self.flushDeferredRequests();
        return true;
    }

    fn routeToVim(self: LspBridge, rid: u32, resp: LspResponse) void {
        const pending = self.transport.requests.removeLsp(rid) orelse {
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
            self.transport.sendResponseTo(pending.client_id, alloc, pending.vim_request_id, .null);
            return;
        }

        const tctx = self.transformContext(pending.lsp_client_key);
        const transformed = pending.transform(alloc, resp.result, tctx);
        log.debug("LSP response [{any}]: {s} -> Vim[{d}] (null={any})", .{ resp.id, pending.method, pending.client_id, transformed == .null });
        self.transport.sendResponseTo(pending.client_id, alloc, pending.vim_request_id, transformed);
    }

    fn transformContext(self: LspBridge, client_key: ?[]const u8) lsp_transform.TransformContext {
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

    const ServerRequest = lsp_client_mod.LspMessage.ServerRequest;

    /// Known server request methods that we acknowledge silently.
    const silent_server_requests: []const []const u8 = &.{
        "window/workDoneProgress/create",
        "client/registerCapability",
        "client/unregisterCapability",
    };

    fn handleServerRequest(self: LspBridge, client_key: []const u8, req: ServerRequest) void {
        const lsp_client = self.lsp.registry.getClient(client_key) orelse return;

        if (std.mem.eql(u8, req.method, "workspace/applyEdit")) {
            self.handleApplyEdit(client_key, lsp_client, req);
            return;
        }

        // Log unknown requests, acknowledge all with null
        if (!isSilentRequest(req.method)) {
            log.debug("Unknown server request: {s} (id={any})", .{ req.method, req.id });
        }
        lsp_client.sendResponse(req.id, .null) catch |e| {
            log.err("Failed to respond to {s}: {any}", .{ req.method, e });
        };
    }

    fn handleApplyEdit(self: LspBridge, client_key: []const u8, lsp_client: *lsp_client_mod.LspClient, req: ServerRequest) void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        const result = json_utils.structToValue(alloc, .{ .applied = true }) catch .null;
        lsp_client.sendResponse(req.id, result) catch |e| {
            log.err("Failed to respond to workspace/applyEdit: {any}", .{e});
        };

        const workspace_uri = lsp_mod.extractWorkspaceFromKey(client_key);
        const encoded = (rpc.Message{ .notification = .{ .method = "applyEdit", .params = req.params } }).serialize(alloc) catch return;
        self.transport.sendToWorkspace(workspace_uri, encoded);
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

    fn handleNotification(self: LspBridge, client_key: []const u8, method: []const u8, params: Value) void {
        if (std.mem.eql(u8, method, "$/progress")) {
            self.handleProgress(client_key, params);
        } else if (std.mem.eql(u8, method, "textDocument/publishDiagnostics")) {
            self.forwardDiagnostics(client_key, params);
        } else {
            log.debug("LSP notification: {s}", .{method});
        }
    }

    fn handleProgress(self: LspBridge, client_key: []const u8, params: Value) void {
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
            if (token) |tk| if (pv.title) |t| self.progress.storeTitle(tk, t);
            self.sendProgressToast(workspace_uri, alloc, pv.title, pv.message, pv.percentage);
        } else if (std.mem.eql(u8, pv.kind, "report")) {
            const title = if (token) |tk| self.progress.getTitle(tk) else null;
            self.sendProgressToast(workspace_uri, alloc, title, pv.message, pv.percentage);
        } else if (std.mem.eql(u8, pv.kind, "end")) {
            if (token) |tk| self.progress.removeTitle(tk);
            self.lsp.decrementIndexingCount(language);
            if (!self.lsp.isAnyLanguageIndexing()) {
                if (lsp_transform.formatToastCmd(alloc, "[yac] Indexing complete", null)) |cmd|
                    self.transport.sendExToWorkspace(workspace_uri, alloc, cmd);
                self.flushDeferredRequests();
            }
        }
    }

    fn sendProgressToast(self: LspBridge, workspace_uri: ?[]const u8, alloc: Allocator, title: ?[]const u8, message: ?[]const u8, percentage: ?i64) void {
        if (lsp_transform.formatProgressToast(alloc, title, message, percentage)) |cmd|
            self.transport.sendExToWorkspace(workspace_uri, alloc, cmd);
    }

    fn forwardDiagnostics(self: LspBridge, client_key: []const u8, params: Value) void {
        const workspace_uri = lsp_mod.extractWorkspaceFromKey(client_key);
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const encoded = (rpc.Message{ .notification = .{ .method = "diagnostics", .params = params } }).serialize(arena.allocator()) catch return;
        self.transport.sendToWorkspace(workspace_uri, encoded);
    }

    // ----------------------------------------------------------------
    // Server death
    // ----------------------------------------------------------------

    fn handleDeath(self: LspBridge, client_key: []const u8) void {
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
            self.transport.sendExToWorkspace(workspace_uri, alloc, cmd);

        self.lsp.registry.removeClient(client_key);
    }

    fn readStderr(client: ?*lsp_client_mod.LspClient) ?[]const u8 {
        const stderr_file = (client orelse return null).child.stderr orelse return null;
        var buf: [4096]u8 = undefined;
        const n = stderr_file.read(&buf) catch return null;
        if (n == 0) return null;
        log.err("LSP stderr: {s}", .{buf[0..n]});
        return buf[0..@min(n, 200)];
    }

    // ----------------------------------------------------------------
    // Deferred request flush
    // ----------------------------------------------------------------

    /// After LSP indexing completes, re-route queued requests back to work queues.
    fn flushDeferredRequests(self: LspBridge) void {
        var requests = self.lsp.takeDeferredRequests();
        defer {
            for (requests.items) |req| self.allocator.free(req.raw_line);
            requests.deinit(self.allocator);
        }

        for (requests.items) |req| {
            const client = self.transport.clients.get(req.client_id) orelse continue;
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
