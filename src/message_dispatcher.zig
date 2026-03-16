const std = @import("std");
const json_utils = @import("json_utils.zig");
const rpc = @import("rpc.zig");
const lsp_registry_mod = @import("lsp/registry.zig");
const handlers_mod = @import("handlers.zig");
const picker_mod = @import("picker.zig");
const log = @import("log.zig");
const lsp_transform = @import("lsp/transform.zig");
const clients_mod = @import("clients.zig");
const vim_expr_tracker_mod = @import("vim_expr_tracker.zig");
const lsp_mod = @import("lsp/lsp.zig");
const treesitter_mod = @import("treesitter/treesitter.zig");
const queue_mod = @import("queue.zig");
const vim_transport_mod = @import("vim_transport.zig");
const dap_bridge_mod = @import("dap_bridge.zig");
const lsp_bridge_mod = @import("lsp_bridge.zig");

const Allocator = std.mem.Allocator;
const Value = json_utils.Value;
const ClientId = clients_mod.ClientId;
const PendingVimExpr = vim_expr_tracker_mod.PendingVimExpr;

/// Handles JSON parsing, RPC dispatch, and response routing for Vim messages.
/// Pure message-processing logic — no I/O, no poll, no fd management.
/// Constructed by EventLoop.initBridges() with pointers to shared state.
pub const MessageDispatcher = struct {
    allocator: Allocator,
    lsp: *lsp_mod.Lsp,
    lsp_bridge: *lsp_bridge_mod.LspBridge,
    picker: *picker_mod.Picker,
    expr_tracker: *vim_expr_tracker_mod.VimExprTracker,
    ts: *treesitter_mod.TreeSitter,
    dap: *dap_bridge_mod.DapBridge,
    clients: *clients_mod.Clients,
    out_queue: *queue_mod.SendChannel,
    shutdown_requested: *bool,

    /// Construct a VimTransport for sending messages to Vim clients.
    fn transport(self: *MessageDispatcher) vim_transport_mod.VimTransport {
        return .{
            .allocator = self.allocator,
            .out_queue = self.out_queue,
            .clients = self.clients,
            .expr_tracker = self.expr_tracker,
        };
    }

    // ====================================================================
    // Entry points — preparse (no lock) + dispatchPreparsed (under lock)
    // ====================================================================

    /// Result of the lock-free preparse phase.
    pub const PreparsedMsg = struct {
        parsed: std.json.Parsed(Value),
        arr: []Value,
        trimmed: []const u8,
    };

    /// Phase 1 (no lock): trim, JSON parse, extract array.
    /// Returns null if the line is empty or malformed.
    pub fn preparse(item: queue_mod.Envelope, alloc: Allocator) ?PreparsedMsg {
        const trimmed = std.mem.trim(u8, item.raw_line, &std.ascii.whitespace);
        if (trimmed.len == 0) return null;

        const parsed = json_utils.parse(alloc, trimmed) catch |e| {
            log.err("JSON parse error: {any}", .{e});
            return null;
        };

        const arr = switch (parsed.value) {
            .array => |a| a.items,
            else => {
                log.err("Expected JSON array from Vim", .{});
                return null;
            },
        };

        return .{ .parsed = parsed, .arr = arr, .trimmed = trimmed };
    }

    /// Phase 2 (under state_lock): expr check, RPC deserialize, handler dispatch.
    pub fn dispatchPreparsed(self: *MessageDispatcher, pre: PreparsedMsg, item: queue_mod.Envelope, alloc: Allocator) void {
        const arr = pre.arr;

        // Intercept responses to our pending expr requests.
        // Vim sends [positive_id, result] which parseJsonRpc would misinterpret.
        if (arr.len == 2 and arr[0] == .integer) {
            if (self.expr_tracker.take(arr[0].integer)) |pending| {
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
                self.handleVimRequest(item.client_id, alloc, r.id, r.method, r.params, pre.trimmed, item.client_stream);
            },
            .notification => |n| {
                log.debug("Vim[{d}] notification: {s}", .{ item.client_id, n.method });
                self.handleVimRequest(item.client_id, alloc, null, n.method, n.params, pre.trimmed, item.client_stream);
            },
            .response => {
                // Responses to Vim "call" commands (expr responses intercepted above)
            },
        }
    }

    // ====================================================================
    // Request handling
    // ====================================================================

    /// Handle a Vim request or notification.
    fn handleVimRequest(self: *MessageDispatcher, cid: ClientId, alloc: Allocator, vim_id: ?u64, method: []const u8, params: Value, raw_line: []const u8, client_stream: std.net.Stream) void {
        // Defer query methods while the relevant LSP server is indexing
        if (vim_id != null and self.lsp.shouldDefer(method, json_utils.getStringField(params, "file"))) {
            if (self.lsp.enqueueDeferred(cid, raw_line)) {
                log.info("Deferred {s} request (LSP indexing in progress)", .{method});
                if (lsp_transform.formatToastCmd(alloc, "[yac] LSP indexing, request queued...", null)) |cmd|
                    self.transport().sendExTo(cid, alloc, cmd);
            }
            return;
        }

        var ctx = handlers_mod.HandlerContext{
            .allocator = alloc,
            .gpa_allocator = self.allocator,
            .registry = &self.lsp.registry,
            .lsp_state = self.lsp,
            .client_stream = client_stream,
            .client_id = cid,
            .ts = self.ts,
            .dap = self.dap,
            .picker = self.picker,
            .out_queue = self.out_queue,
            .shutdown_flag = self.shutdown_requested,
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
            self.lsp_bridge.trackPendingRequest(pending.request_id, cid, vim_id, method, params, pending.client_key, pending.transform);
        } else if (ctx._picker_query_buffers) {
            // Picker open: send expr to get buffer list, response triggers handleVimExprResponse
            self.transport().sendExprTo(cid, alloc, vim_id, "map(getbufinfo({'buflisted':1}), {_, b -> b.name})", .picker_buffers);
        } else if (result) |data| {
            if (ctx._subscribe_workspace) |ws| {
                self.clients.subscribeClient(cid, ws);
            }
            self.transport().sendResponseTo(cid, alloc, vim_id, data);
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

    // ====================================================================
    // Callbacks
    // ====================================================================

    /// Handle the result of a daemon->Vim expr request.
    fn handleVimExprResponse(self: *MessageDispatcher, alloc: Allocator, pending: PendingVimExpr, result: Value) void {
        switch (pending.tag) {
            .picker_buffers => {
                const data = self.picker.mergeBufferList(alloc, result);
                self.transport().sendResponseTo(pending.cid, alloc, pending.vim_id, data);
            },
        }
    }

    /// After did_save, tell other clients in the same workspace to checktime
    /// so they reload externally modified files immediately.
    fn broadcastChecktimeToOthers(self: *MessageDispatcher, sender_cid: ClientId, alloc: Allocator, params: Value) void {
        const file = json_utils.getStringField(params, "file") orelse return;
        const real_path = lsp_registry_mod.extractRealPath(file);
        const language = lsp_registry_mod.LspRegistry.detectLanguage(real_path) orelse return;
        const client_result = self.lsp.registry.findClient(language, real_path) orelse return;
        const workspace_uri = lsp_mod.extractWorkspaceFromKey(client_result.client_key) orelse return;
        self.transport().broadcastExToOthers(sender_cid, workspace_uri, alloc, "silent! checktime");
    }
};
