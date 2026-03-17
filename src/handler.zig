const std = @import("std");
const json = @import("json_utils.zig");
const log = @import("log.zig");
const vim = @import("vim_protocol.zig");
const lsp_registry_mod = @import("lsp/registry.zig");
const lsp_mod = @import("lsp/lsp.zig");
const lsp_client_mod = @import("lsp/client.zig");
const treesitter_mod = @import("treesitter/treesitter.zig");
const dap_session_mod = @import("dap/session.zig");
const dap_client_mod = @import("dap/client.zig");
const dap_config = @import("dap/config.zig");
const dap_protocol = @import("dap/protocol.zig");
const queue_mod = @import("queue.zig");
const clients_mod = @import("clients.zig");
const vim_server_mod = @import("vim_server.zig");

const Allocator = std.mem.Allocator;
const Value = json.Value;
const ObjectMap = json.ObjectMap;
const LspRegistry = lsp_registry_mod.LspRegistry;
const LspClient = lsp_client_mod.LspClient;
const ClientId = clients_mod.ClientId;
const ProcessResult = vim_server_mod.ProcessResult;
const DapClient = dap_client_mod.DapClient;
const DapSession = dap_session_mod.DapSession;
const ts_mod = treesitter_mod;

// ============================================================================
// LSP context types (migrated from handlers/common.zig)
// ============================================================================

const LspContext = struct {
    language: []const u8,
    client_key: []const u8,
    uri: []const u8,
    client: *LspClient,
    ssh_host: ?[]const u8,
    real_path: []const u8,
};

const LspContextResult = union(enum) {
    ready: LspContext,
    initializing: void,
    not_available: void,
};

// ============================================================================
// Tree-sitter context
// ============================================================================

const TsContext = struct {
    ts: *ts_mod.TreeSitter,
    file: []const u8,
    lang_state: *const ts_mod.LangState,
};

// ============================================================================
// Pure helper functions (free functions, not methods)
// ============================================================================

fn buildTextDocumentPosition(allocator: Allocator, uri: []const u8, line: u32, column: u32) !Value {
    return json.buildObject(allocator, .{
        .{ "textDocument", try buildTextDocumentValue(allocator, uri) },
        .{ "position", try json.buildObject(allocator, .{
            .{ "line", json.jsonInteger(@intCast(line)) },
            .{ "character", json.jsonInteger(@intCast(column)) },
        }) },
    });
}

fn buildRange(allocator: Allocator, start_line: u32, start_col: u32, end_line: u32, end_col: u32) !Value {
    return json.buildObject(allocator, .{
        .{ "start", try json.buildObject(allocator, .{
            .{ "line", json.jsonInteger(@intCast(start_line)) },
            .{ "character", json.jsonInteger(@intCast(start_col)) },
        }) },
        .{ "end", try json.buildObject(allocator, .{
            .{ "line", json.jsonInteger(@intCast(end_line)) },
            .{ "character", json.jsonInteger(@intCast(end_col)) },
        }) },
    });
}

fn buildTextDocumentValue(allocator: Allocator, uri: []const u8) !Value {
    return json.buildObject(allocator, .{
        .{ "uri", json.jsonString(uri) },
    });
}

fn buildTextDocumentIdentifier(allocator: Allocator, uri: []const u8) !Value {
    return json.buildObject(allocator, .{
        .{ "textDocument", try buildTextDocumentValue(allocator, uri) },
    });
}

/// Build LSP FormattingOptions from typed params.
fn buildFormattingOptionsTyped(allocator: Allocator, tab_size: i64, insert_spaces: bool) !Value {
    return json.buildObject(allocator, .{
        .{ "tabSize", json.jsonInteger(tab_size) },
        .{ "insertSpaces", json.jsonBool(insert_spaces) },
    });
}

/// Parse a path array [0, 2, 1] from a Value.
fn parsePathFromValue(alloc: Allocator, path_val: ?Value) !?[]const u32 {
    const path_arr = switch (path_val orelse return null) {
        .array => |a| a,
        else => return null,
    };
    const path = try alloc.alloc(u32, path_arr.items.len);
    for (path_arr.items, 0..) |item, i| {
        path[i] = switch (item) {
            .integer => |val| @intCast(val),
            else => {
                alloc.free(path);
                return null;
            },
        };
    }
    return path;
}

// ============================================================================
// Copilot module-level state (global, not per-Handler)
// ============================================================================

/// Track which URIs have been didOpen'd to the Copilot client.
/// Reset when copilot client is recreated (spawn_failed resets).
var copilot_opened_uris: std.StringHashMap(void) = std.StringHashMap(void).init(std.heap.page_allocator);

// ============================================================================
// Handler — Vim method handlers for VimServer dispatch.
//
// Each pub fn whose first param is *Handler is a Vim method handler.
// Function name = Vim method name (e.g., "exit", "hover", "did_change").
// ============================================================================

pub const Handler = struct {
    // Long-lived subsystem references (set once, stable across requests)
    registry: *LspRegistry,
    lsp: *lsp_mod.Lsp,
    ts: *treesitter_mod.TreeSitter,
    dap_session: *?*DapSession,
    out_queue: *queue_mod.OutQueue,
    gpa: Allocator,
    shutdown_flag: *bool,

    // Per-request context (set before each dispatch)
    client_id: ClientId = 0,
    client_stream: std.net.Stream = undefined,

    // ========================================================================
    // Private helper methods
    // ========================================================================

    fn getLspCtx(self: *Handler, alloc: Allocator, file: []const u8) !LspContextResult {
        return self.getLspCtxEx(alloc, file, true);
    }

    fn getLspCtxEx(self: *Handler, alloc: Allocator, file: []const u8, require_ready: bool) !LspContextResult {
        const real_path = lsp_registry_mod.extractRealPath(file);
        const ssh_host = lsp_registry_mod.extractSshHost(file);

        const language = LspRegistry.detectLanguage(real_path) orelse {
            log.debug("No language detected for {s}", .{real_path});
            return .{ .not_available = {} };
        };

        if (self.registry.hasSpawnFailed(language)) {
            return .{ .not_available = {} };
        }

        const result = self.registry.getOrCreateClient(language, real_path) catch |e| {
            log.err("LSP server not available for {s}: {any}", .{ language, e });
            self.registry.markSpawnFailed(language);
            const config = LspRegistry.getConfig(language);
            const cmd = if (config) |c| c.command else language;
            if (std.mem.indexOfScalar(u8, language, '\'') != null or
                std.mem.indexOfScalar(u8, cmd, '\'') != null)
            {
                return .{ .not_available = {} };
            }
            const msg = std.fmt.allocPrint(alloc, "call yac_install#on_spawn_failed('{s}', '{s}')", .{ language, cmd }) catch {
                return .{ .not_available = {} };
            };
            self.vimEx(alloc, msg) catch {};
            return .{ .not_available = {} };
        };

        if (require_ready and self.registry.isInitializing(result.client_key)) return .{ .initializing = {} };

        const uri = try lsp_registry_mod.filePathToUri(alloc, real_path);

        return .{ .ready = .{
            .language = language,
            .client_key = result.client_key,
            .uri = uri,
            .client = result.client,
            .ssh_host = ssh_host,
            .real_path = real_path,
        } };
    }

    fn sendPositionRequest(self: *Handler, alloc: Allocator, file: []const u8, line: u32, column: u32, lsp_method: []const u8) !ProcessResult {
        const lsp_ctx = switch (try self.getLspCtx(alloc, file)) {
            .ready => |c| c,
            .initializing => return .{ .initializing = {} },
            .not_available => return .{ .empty = {} },
        };

        const lsp_params = try buildTextDocumentPosition(alloc, lsp_ctx.uri, line, column);
        const request_id = try lsp_ctx.client.sendRequest(lsp_method, lsp_params);

        return .{ .pending_lsp = .{ .lsp_request_id = request_id } };
    }

    fn sendCapabilityCheckedPositionRequest(self: *Handler, alloc: Allocator, file: []const u8, line: u32, column: u32, lsp_method: []const u8, capability: []const u8, feature_name: []const u8) !ProcessResult {
        const lsp_ctx = switch (try self.getLspCtx(alloc, file)) {
            .ready => |c| c,
            .initializing => return .{ .initializing = {} },
            .not_available => return .{ .empty = {} },
        };

        if (self.checkUnsupported(alloc, lsp_ctx.client_key, capability, feature_name)) return .{ .empty = {} };

        const lsp_params = try buildTextDocumentPosition(alloc, lsp_ctx.uri, line, column);
        const request_id = try lsp_ctx.client.sendRequest(lsp_method, lsp_params);

        return .{ .pending_lsp = .{ .lsp_request_id = request_id } };
    }

    fn checkUnsupported(self: *Handler, alloc: Allocator, client_key: []const u8, capability: []const u8, feature_name: []const u8) bool {
        if (!self.registry.serverSupports(client_key, capability)) {
            const msg = std.fmt.allocPrint(alloc, "call yac#toast('[yac] Server does not support {s}')", .{feature_name}) catch return true;
            self.vimEx(alloc, msg) catch {};
            return true;
        }
        return false;
    }

    fn vimEx(self: *Handler, alloc: Allocator, command: []const u8) !void {
        const encoded = try vim.encodeChannelCommand(alloc, .{ .ex = .{ .command = command } });
        defer alloc.free(encoded);
        const msg = try self.gpa.alloc(u8, encoded.len + 1);
        @memcpy(msg[0..encoded.len], encoded);
        msg[encoded.len] = '\n';
        if (!self.out_queue.push(.{ .stream = self.client_stream, .bytes = msg })) {
            self.gpa.free(msg);
            log.warn("vimEx: out queue full, dropping command", .{});
        }
    }

    fn vimCallAsync(self: *Handler, alloc: Allocator, func: []const u8, args: Value) !void {
        const encoded = try vim.encodeChannelCommand(alloc, .{ .call_async = .{
            .func = func,
            .args = args,
        } });
        defer alloc.free(encoded);
        const msg = try self.gpa.alloc(u8, encoded.len + 1);
        @memcpy(msg[0..encoded.len], encoded);
        msg[encoded.len] = '\n';
        if (!self.out_queue.push(.{ .stream = self.client_stream, .bytes = msg })) {
            self.gpa.free(msg);
            log.warn("vimCallAsync: out queue full, dropping call", .{});
        }
    }

    // ── Tree-sitter helpers ──

    fn getTsCtx(self: *Handler, file: []const u8, text: ?[]const u8) ?TsContext {
        const ts_state = self.ts;
        const lang_state = ts_state.fromExtension(file) orelse return null;

        // Auto-parse if buffer not yet tracked
        if (ts_state.getTree(file) == null) {
            if (text) |t| {
                ts_state.parseBuffer(file, t) catch |e| {
                    log.debug("TreeSitter auto-parse failed for {s}: {any}", .{ file, e });
                };
            }
        }

        return .{ .ts = ts_state, .file = file, .lang_state = lang_state };
    }

    fn parseIfSupported(self: *Handler, file: []const u8, text: ?[]const u8) void {
        const tc = self.getTsCtx(file, text) orelse return;
        const t = text orelse return;
        tc.ts.parseBuffer(tc.file, t) catch |e| {
            log.debug("TreeSitter parse failed for {s}: {any}", .{ tc.file, e });
        };
    }

    fn removeIfSupported(self: *Handler, file: []const u8) void {
        const tc = self.getTsCtx(file, null) orelse return;
        tc.ts.removeBuffer(tc.file);
    }

    // ── Copilot helpers ──

    fn getCopilotClient(self: *Handler, alloc: Allocator) ?*LspClient {
        const client = self.registry.getOrCreateCopilotClient() orelse {
            const msg = "call yac#toast('[yac] copilot-language-server not found. Install: npm i -g @github/copilot-language-server')";
            self.vimEx(alloc, msg) catch {};
            return null;
        };
        return client;
    }

    fn copilotReady(self: *Handler) bool {
        return !self.registry.isInitializing(LspRegistry.copilot_key);
    }

    fn ensureCopilotDidOpen(_: *Handler, alloc: Allocator, client: *LspClient, file: []const u8) void {
        const real_path = lsp_registry_mod.extractRealPath(file);
        const uri = lsp_registry_mod.filePathToUri(alloc, real_path) catch return;

        if (copilot_opened_uris.contains(uri)) return;

        const content = std.fs.cwd().readFileAlloc(alloc, real_path, 10 * 1024 * 1024) catch return;
        const lang = LspRegistry.detectLanguage(real_path) orelse "plaintext";

        var td_item = ObjectMap.init(alloc);
        td_item.put("uri", json.jsonString(uri)) catch return;
        td_item.put("languageId", json.jsonString(lang)) catch return;
        td_item.put("version", json.jsonInteger(1)) catch return;
        td_item.put("text", json.jsonString(content)) catch return;

        var params_obj = ObjectMap.init(alloc);
        params_obj.put("textDocument", .{ .object = td_item }) catch return;

        client.sendNotification("textDocument/didOpen", .{ .object = params_obj }) catch |e| {
            log.err("Failed to send didOpen to Copilot: {any}", .{e});
            return;
        };

        const uri_owned = std.heap.page_allocator.dupe(u8, uri) catch return;
        copilot_opened_uris.put(uri_owned, {}) catch {
            std.heap.page_allocator.free(uri_owned);
        };
        log.info("Sent didOpen to Copilot for {s}", .{uri});
    }

    // ── DAP helpers ──

    fn notRunning(self: *Handler, alloc: Allocator) !ProcessResult {
        const msg = "call yac#toast('[yac] No active debug session')";
        try self.vimEx(alloc, msg);
        return .{ .empty = {} };
    }

    fn handleThreadControl(self: *Handler, alloc: Allocator, thread_id_param: ?u32, comptime sendFn: fn (*DapClient, u32) anyerror!u32) !ProcessResult {
        const session = self.dap_session.* orelse return self.notRunning(alloc);

        const thread_id = thread_id_param orelse session.client.active_thread_id orelse 1;
        _ = try sendFn(session.client, thread_id);
        return .{ .data = try json.buildObject(alloc, .{
            .{ "ok", .{ .bool = true } },
        }) };
    }

    fn sendEmptyConfigs(self: *Handler, alloc: Allocator) !void {
        var args_array = std.json.Array.init(alloc);
        try args_array.append(.{ .array = std.json.Array.init(alloc) });
        try self.vimCallAsync(alloc, "yac_dap#on_debug_configs", .{ .array = args_array });
    }

    // ── Copilot forwarding helpers (for file_open / did_change) ──

    fn forwardDidOpenToCopilot(self: *Handler, alloc: Allocator, file: []const u8, text: ?[]const u8) void {
        if (self.registry.copilot_client == null) return;

        const real_path = lsp_registry_mod.extractRealPath(file);
        const uri = lsp_registry_mod.filePathToUri(alloc, real_path) catch return;
        const content = text orelse
            (std.fs.cwd().readFileAlloc(alloc, real_path, 10 * 1024 * 1024) catch return);
        const lang = LspRegistry.detectLanguage(real_path) orelse "plaintext";

        if (self.registry.isInitializing(LspRegistry.copilot_key)) {
            self.registry.queuePendingOpen(LspRegistry.copilot_key, uri, lang, content) catch |e| {
                log.err("Failed to queue pending didOpen for Copilot: {any}", .{e});
            };
            return;
        }

        const copilot_client = self.registry.copilot_client orelse return;

        var td_item = ObjectMap.init(alloc);
        td_item.put("uri", json.jsonString(uri)) catch return;
        td_item.put("languageId", json.jsonString(lang)) catch return;
        td_item.put("version", json.jsonInteger(1)) catch return;
        td_item.put("text", json.jsonString(content)) catch return;

        var params_obj = ObjectMap.init(alloc);
        params_obj.put("textDocument", .{ .object = td_item }) catch return;

        copilot_client.sendNotification("textDocument/didOpen", .{ .object = params_obj }) catch |e| {
            log.err("Failed to send didOpen to Copilot: {any}", .{e});
            return;
        };
        log.info("Forwarded didOpen to Copilot for {s}", .{uri});
    }

    fn forwardDidChangeToCopilot(self: *Handler, alloc: Allocator, file: []const u8, version: i64, changes: ?Value, text: ?[]const u8) void {
        const copilot_client = self.registry.copilot_client orelse return;
        if (self.registry.isInitializing(LspRegistry.copilot_key)) return;

        const real_path = lsp_registry_mod.extractRealPath(file);
        const uri = lsp_registry_mod.filePathToUri(alloc, real_path) catch return;

        var td = ObjectMap.init(alloc);
        td.put("uri", json.jsonString(uri)) catch return;
        td.put("version", json.jsonInteger(version)) catch return;

        var lsp_params = ObjectMap.init(alloc);
        lsp_params.put("textDocument", .{ .object = td }) catch return;

        if (changes) |c| {
            lsp_params.put("contentChanges", c) catch return;
        } else if (text) |t| {
            var change = ObjectMap.init(alloc);
            change.put("text", json.jsonString(t)) catch return;
            var changes_arr = std.json.Array.init(alloc);
            changes_arr.append(.{ .object = change }) catch return;
            lsp_params.put("contentChanges", .{ .array = changes_arr }) catch return;
        }

        copilot_client.sendNotification("textDocument/didChange", .{ .object = lsp_params }) catch |e| {
            log.err("Failed to send didChange to Copilot: {any}", .{e});
        };
    }

    // ========================================================================
    // System handlers
    // ========================================================================

    pub fn exit(self: *Handler) ![]const u8 {
        log.info("Exit requested by client {d}", .{self.client_id});
        self.shutdown_flag.* = true;
        return "ok";
    }

    pub fn ping(_: *Handler) ![]const u8 {
        return "pong";
    }

    // ========================================================================
    // LSP status/lifecycle
    // ========================================================================

    pub fn lsp_status(self: *Handler, alloc: Allocator, p: struct {
        file: []const u8,
    }) !Value {
        const real_path = lsp_registry_mod.extractRealPath(p.file);
        const language = LspRegistry.detectLanguage(real_path) orelse {
            return try json.buildObject(alloc, .{
                .{ "ready", .{ .bool = false } },
                .{ "reason", json.jsonString("unsupported_language") },
            });
        };

        const client_result = self.registry.findClient(language, real_path);

        if (client_result) |cr| {
            const initializing = self.registry.isInitializing(cr.client_key);
            const state = cr.client.state;
            const lang_from_key = lsp_mod.extractLanguageFromKey(cr.client_key);
            const indexing = self.lsp.isLanguageIndexing(lang_from_key);
            const ready = state == .initialized and !initializing and !indexing;

            return try json.buildObject(alloc, .{
                .{ "ready", json.jsonBool(ready) },
                .{ "state", json.jsonString(@tagName(state)) },
                .{ "initializing", json.jsonBool(initializing) },
                .{ "indexing", json.jsonBool(indexing) },
            });
        } else {
            return try json.buildObject(alloc, .{
                .{ "ready", .{ .bool = false } },
                .{ "reason", json.jsonString("no_client") },
            });
        }
    }

    // file_open kept as raw Value — complex flow with copilot forwarding and raw Value access
    pub fn file_open(self: *Handler, alloc: Allocator, p: struct {
        file: []const u8,
        text: ?[]const u8 = null,
    }) !ProcessResult {
        self.parseIfSupported(p.file, p.text);

        const lsp_ctx_result = try self.getLspCtxEx(alloc, p.file, false);

        var workspace_uri: ?[]const u8 = null;

        switch (lsp_ctx_result) {
            .ready => |lsp_ctx| {
                workspace_uri = lsp_mod.extractWorkspaceFromKey(lsp_ctx.client_key);

                const content_to_use = p.text orelse
                    (std.fs.cwd().readFileAlloc(alloc, lsp_ctx.real_path, 10 * 1024 * 1024) catch |e| {
                        log.err("Failed to read file {s}: {any}", .{ lsp_ctx.real_path, e });
                        return .{ .empty = {} };
                    });

                if (self.registry.isInitializing(lsp_ctx.client_key)) {
                    self.registry.queuePendingOpen(lsp_ctx.client_key, lsp_ctx.uri, lsp_ctx.language, content_to_use) catch |e| {
                        log.err("Failed to queue pending open: {any}", .{e});
                    };
                } else {
                    var td_item = ObjectMap.init(alloc);
                    try td_item.put("uri", json.jsonString(lsp_ctx.uri));
                    try td_item.put("languageId", json.jsonString(lsp_ctx.language));
                    try td_item.put("version", json.jsonInteger(1));
                    try td_item.put("text", json.jsonString(content_to_use));

                    var did_open_params = ObjectMap.init(alloc);
                    try did_open_params.put("textDocument", .{ .object = td_item });

                    lsp_ctx.client.sendNotification("textDocument/didOpen", .{ .object = did_open_params }) catch |e| {
                        log.err("Failed to send didOpen: {any}", .{e});
                    };
                }
            },
            .initializing, .not_available => {},
        }

        self.forwardDidOpenToCopilot(alloc, p.file, p.text);

        const result_data = try json.buildObject(alloc, .{
            .{ "action", json.jsonString("none") },
        });

        if (workspace_uri) |ws| {
            return .{ .data_with_subscribe = .{ .data = result_data, .workspace_uri = ws } };
        }
        return .{ .data = result_data };
    }

    pub fn lsp_reset_failed(self: *Handler, alloc: Allocator, p: struct {
        language: []const u8,
    }) !ProcessResult {
        self.registry.resetSpawnFailed(p.language);

        return .{ .data = try json.buildObject(alloc, .{
            .{ "ok", .{ .bool = true } },
        }) };
    }

    // ========================================================================
    // LSP navigation
    // ========================================================================

    pub fn goto_definition(self: *Handler, alloc: Allocator, p: struct {
        file: []const u8,
        line: u32,
        column: u32,
    }) !ProcessResult {
        return self.sendPositionRequest(alloc, p.file, p.line, p.column, "textDocument/definition");
    }

    pub fn goto_declaration(self: *Handler, alloc: Allocator, p: struct {
        file: []const u8,
        line: u32,
        column: u32,
    }) !ProcessResult {
        return self.sendPositionRequest(alloc, p.file, p.line, p.column, "textDocument/declaration");
    }

    pub fn goto_type_definition(self: *Handler, alloc: Allocator, p: struct {
        file: []const u8,
        line: u32,
        column: u32,
    }) !ProcessResult {
        return self.sendPositionRequest(alloc, p.file, p.line, p.column, "textDocument/typeDefinition");
    }

    pub fn goto_implementation(self: *Handler, alloc: Allocator, p: struct {
        file: []const u8,
        line: u32,
        column: u32,
    }) !ProcessResult {
        return self.sendPositionRequest(alloc, p.file, p.line, p.column, "textDocument/implementation");
    }

    pub fn references(self: *Handler, alloc: Allocator, p: struct {
        file: []const u8,
        line: u32,
        column: u32,
    }) !ProcessResult {
        const lsp_ctx = switch (try self.getLspCtx(alloc, p.file)) {
            .ready => |c| c,
            .initializing => return .{ .initializing = {} },
            .not_available => return .{ .empty = {} },
        };

        var lsp_params_obj = switch (try buildTextDocumentPosition(alloc, lsp_ctx.uri, p.line, p.column)) {
            .object => |o| o,
            else => unreachable,
        };

        try lsp_params_obj.put("context", try json.buildObject(alloc, .{
            .{ "includeDeclaration", json.jsonBool(true) },
        }));

        const request_id = try lsp_ctx.client.sendRequest("textDocument/references", .{ .object = lsp_params_obj });

        return .{ .pending_lsp = .{ .lsp_request_id = request_id } };
    }

    pub fn call_hierarchy(self: *Handler, alloc: Allocator, p: struct {
        file: []const u8,
        line: u32,
        column: u32,
    }) !ProcessResult {
        return self.sendPositionRequest(alloc, p.file, p.line, p.column, "textDocument/prepareCallHierarchy");
    }

    pub fn type_hierarchy(self: *Handler, alloc: Allocator, p: struct {
        file: []const u8,
        line: u32,
        column: u32,
    }) !ProcessResult {
        return self.sendCapabilityCheckedPositionRequest(alloc, p.file, p.line, p.column, "textDocument/prepareTypeHierarchy", "typeHierarchyProvider", "type hierarchy");
    }

    // ========================================================================
    // LSP info
    // ========================================================================

    pub fn hover(self: *Handler, alloc: Allocator, p: struct {
        file: []const u8,
        line: u32,
        column: u32,
    }) !ProcessResult {
        return self.sendPositionRequest(alloc, p.file, p.line, p.column, "textDocument/hover");
    }

    pub fn completion(self: *Handler, alloc: Allocator, p: struct {
        file: []const u8,
        line: u32,
        column: u32,
    }) !ProcessResult {
        const lsp_ctx = switch (try self.getLspCtx(alloc, p.file)) {
            .ready => |c| c,
            .initializing => return .{ .initializing = {} },
            .not_available => return .{ .empty = {} },
        };

        const lsp_params = try buildTextDocumentPosition(alloc, lsp_ctx.uri, p.line, p.column);
        const request_id = try lsp_ctx.client.sendRequest("textDocument/completion", lsp_params);

        return .{ .pending_lsp = .{ .lsp_request_id = request_id, .client_key = lsp_ctx.client_key } };
    }

    pub fn document_symbols(self: *Handler, alloc: Allocator, p: struct {
        file: []const u8,
    }) !ProcessResult {
        const lsp_ctx = switch (try self.getLspCtx(alloc, p.file)) {
            .ready => |c| c,
            .initializing => return .{ .initializing = {} },
            .not_available => return .{ .empty = {} },
        };

        const lsp_params = try buildTextDocumentIdentifier(alloc, lsp_ctx.uri);
        const request_id = try lsp_ctx.client.sendRequest("textDocument/documentSymbol", lsp_params);

        return .{ .pending_lsp = .{ .lsp_request_id = request_id } };
    }

    pub fn inlay_hints(self: *Handler, alloc: Allocator, p: struct {
        file: []const u8,
        start_line: u32 = 0,
        end_line: u32 = 100,
    }) !ProcessResult {
        const lsp_ctx = switch (try self.getLspCtx(alloc, p.file)) {
            .ready => |c| c,
            .initializing => return .{ .initializing = {} },
            .not_available => return .{ .empty = {} },
        };

        const lsp_params = try json.buildObject(alloc, .{
            .{ "textDocument", try buildTextDocumentValue(alloc, lsp_ctx.uri) },
            .{ "range", try buildRange(alloc, p.start_line, 0, p.end_line, 0) },
        });

        const request_id = try lsp_ctx.client.sendRequest("textDocument/inlayHint", lsp_params);

        return .{ .pending_lsp = .{ .lsp_request_id = request_id } };
    }

    pub fn folding_range(self: *Handler, alloc: Allocator, p: struct {
        file: []const u8,
    }) !ProcessResult {
        const lsp_ctx = switch (try self.getLspCtx(alloc, p.file)) {
            .ready => |c| c,
            .initializing => return .{ .initializing = {} },
            .not_available => return .{ .empty = {} },
        };

        const lsp_params = try buildTextDocumentIdentifier(alloc, lsp_ctx.uri);
        const request_id = try lsp_ctx.client.sendRequest("textDocument/foldingRange", lsp_params);

        return .{ .pending_lsp = .{ .lsp_request_id = request_id } };
    }

    pub fn signature_help(self: *Handler, alloc: Allocator, p: struct {
        file: []const u8,
        line: u32,
        column: u32,
    }) !ProcessResult {
        return self.sendCapabilityCheckedPositionRequest(alloc, p.file, p.line, p.column, "textDocument/signatureHelp", "signatureHelpProvider", "signature help");
    }

    pub fn semantic_tokens(self: *Handler, alloc: Allocator, p: struct {
        file: []const u8,
    }) !ProcessResult {
        const lsp_ctx = switch (try self.getLspCtx(alloc, p.file)) {
            .ready => |c| c,
            .initializing => return .{ .initializing = {} },
            .not_available => return .{ .empty = {} },
        };

        if (self.checkUnsupported(alloc, lsp_ctx.client_key, "semanticTokensProvider", "semantic tokens")) return .{ .empty = {} };

        const lsp_params = try buildTextDocumentIdentifier(alloc, lsp_ctx.uri);
        const request_id = try lsp_ctx.client.sendRequest("textDocument/semanticTokens/full", lsp_params);

        return .{ .pending_lsp = .{ .lsp_request_id = request_id, .client_key = lsp_ctx.client_key } };
    }

    // ========================================================================
    // LSP editing
    // ========================================================================

    pub fn rename(self: *Handler, alloc: Allocator, p: struct {
        file: []const u8,
        line: u32,
        column: u32,
        new_name: []const u8,
    }) !ProcessResult {
        const lsp_ctx = switch (try self.getLspCtx(alloc, p.file)) {
            .ready => |c| c,
            .initializing => return .{ .initializing = {} },
            .not_available => return .{ .empty = {} },
        };

        var lsp_params_obj = switch (try buildTextDocumentPosition(alloc, lsp_ctx.uri, p.line, p.column)) {
            .object => |o| o,
            else => unreachable,
        };
        try lsp_params_obj.put("newName", json.jsonString(p.new_name));

        const request_id = try lsp_ctx.client.sendRequest("textDocument/rename", .{ .object = lsp_params_obj });

        return .{ .pending_lsp = .{ .lsp_request_id = request_id } };
    }

    pub fn code_action(self: *Handler, alloc: Allocator, p: struct {
        file: []const u8,
        line: u32,
        column: u32,
    }) !ProcessResult {
        const lsp_ctx = switch (try self.getLspCtx(alloc, p.file)) {
            .ready => |c| c,
            .initializing => return .{ .initializing = {} },
            .not_available => return .{ .empty = {} },
        };

        const lsp_params = try json.buildObject(alloc, .{
            .{ "textDocument", try buildTextDocumentValue(alloc, lsp_ctx.uri) },
            .{ "range", try buildRange(alloc, p.line, p.column, p.line, p.column) },
            .{ "context", try json.buildObject(alloc, .{
                .{ "diagnostics", .{ .array = std.json.Array.init(alloc) } },
            }) },
        });

        const request_id = try lsp_ctx.client.sendRequest("textDocument/codeAction", lsp_params);

        return .{ .pending_lsp = .{ .lsp_request_id = request_id } };
    }

    pub fn formatting(self: *Handler, alloc: Allocator, p: struct {
        file: []const u8,
        tab_size: i64 = 4,
        insert_spaces: bool = true,
    }) !ProcessResult {
        const lsp_ctx = switch (try self.getLspCtx(alloc, p.file)) {
            .ready => |c| c,
            .initializing => return .{ .initializing = {} },
            .not_available => return .{ .empty = {} },
        };

        if (self.checkUnsupported(alloc, lsp_ctx.client_key, "documentFormattingProvider", "formatting")) return .{ .empty = {} };

        const lsp_params = try json.buildObject(alloc, .{
            .{ "textDocument", try buildTextDocumentValue(alloc, lsp_ctx.uri) },
            .{ "options", try buildFormattingOptionsTyped(alloc, p.tab_size, p.insert_spaces) },
        });

        const request_id = try lsp_ctx.client.sendRequest("textDocument/formatting", lsp_params);

        return .{ .pending_lsp = .{ .lsp_request_id = request_id } };
    }

    pub fn range_formatting(self: *Handler, alloc: Allocator, p: struct {
        file: []const u8,
        start_line: u32 = 0,
        start_column: u32 = 0,
        end_line: u32 = 0,
        end_column: u32 = 0,
        tab_size: i64 = 4,
        insert_spaces: bool = true,
    }) !ProcessResult {
        const lsp_ctx = switch (try self.getLspCtx(alloc, p.file)) {
            .ready => |c| c,
            .initializing => return .{ .initializing = {} },
            .not_available => return .{ .empty = {} },
        };

        if (self.checkUnsupported(alloc, lsp_ctx.client_key, "documentRangeFormattingProvider", "range formatting")) return .{ .empty = {} };

        const lsp_params = try json.buildObject(alloc, .{
            .{ "textDocument", try buildTextDocumentValue(alloc, lsp_ctx.uri) },
            .{ "options", try buildFormattingOptionsTyped(alloc, p.tab_size, p.insert_spaces) },
            .{ "range", try buildRange(alloc, p.start_line, p.start_column, p.end_line, p.end_column) },
        });

        const request_id = try lsp_ctx.client.sendRequest("textDocument/rangeFormatting", lsp_params);

        return .{ .pending_lsp = .{ .lsp_request_id = request_id } };
    }

    pub fn execute_command(self: *Handler, alloc: Allocator, p: struct {
        file: []const u8,
        lsp_command: []const u8,
        arguments: ?Value = null,
    }) !ProcessResult {
        const lsp_ctx = switch (try self.getLspCtx(alloc, p.file)) {
            .ready => |c| c,
            .initializing => return .{ .initializing = {} },
            .not_available => return .{ .empty = {} },
        };

        var lsp_params = try json.buildObjectMap(alloc, .{
            .{ "command", json.jsonString(p.lsp_command) },
        });
        if (p.arguments) |args| {
            try lsp_params.put("arguments", args);
        }

        const request_id = try lsp_ctx.client.sendRequest("workspace/executeCommand", .{ .object = lsp_params });

        return .{ .pending_lsp = .{ .lsp_request_id = request_id } };
    }

    // ========================================================================
    // LSP notifications
    // ========================================================================

    pub fn diagnostics(_: *Handler) !ProcessResult {
        return .{ .empty = {} };
    }

    pub fn did_change(self: *Handler, alloc: Allocator, p: struct {
        file: []const u8,
        version: i64 = 1,
        text: ?[]const u8 = null,
        changes: ?Value = null,
    }) !ProcessResult {
        self.parseIfSupported(p.file, p.text);

        const lsp_ctx_result = try self.getLspCtx(alloc, p.file);
        switch (lsp_ctx_result) {
            .ready => |lsp_ctx| {
                var lsp_params = try json.buildObjectMap(alloc, .{
                    .{ "textDocument", try json.buildObject(alloc, .{
                        .{ "uri", json.jsonString(lsp_ctx.uri) },
                        .{ "version", json.jsonInteger(p.version) },
                    }) },
                });

                if (p.changes) |changes| {
                    try lsp_params.put("contentChanges", changes);
                } else if (p.text) |t| {
                    var change = ObjectMap.init(alloc);
                    try change.put("text", json.jsonString(t));
                    var changes_arr = std.json.Array.init(alloc);
                    try changes_arr.append(.{ .object = change });
                    try lsp_params.put("contentChanges", .{ .array = changes_arr });
                }

                lsp_ctx.client.sendNotification("textDocument/didChange", .{ .object = lsp_params }) catch |e| {
                    log.err("Failed to send didChange: {any}", .{e});
                };
            },
            .initializing, .not_available => {},
        }

        self.forwardDidChangeToCopilot(alloc, p.file, p.version, p.changes, p.text);

        return .{ .empty = {} };
    }

    pub fn did_save(self: *Handler, alloc: Allocator, p: struct {
        file: []const u8,
    }) !ProcessResult {
        const lsp_ctx = switch (try self.getLspCtx(alloc, p.file)) {
            .ready => |c| c,
            .initializing, .not_available => return .{ .empty = {} },
        };

        const lsp_params = try buildTextDocumentIdentifier(alloc, lsp_ctx.uri);

        lsp_ctx.client.sendNotification("textDocument/didSave", lsp_params) catch |e| {
            log.err("Failed to send didSave: {any}", .{e});
        };

        return .{ .empty = {} };
    }

    pub fn did_close(self: *Handler, alloc: Allocator, p: struct {
        file: []const u8,
    }) !ProcessResult {
        self.removeIfSupported(p.file);

        const lsp_ctx = switch (try self.getLspCtx(alloc, p.file)) {
            .ready => |c| c,
            .initializing, .not_available => return .{ .empty = {} },
        };

        const lsp_params = try buildTextDocumentIdentifier(alloc, lsp_ctx.uri);

        lsp_ctx.client.sendNotification("textDocument/didClose", lsp_params) catch |e| {
            log.err("Failed to send didClose: {any}", .{e});
        };

        return .{ .empty = {} };
    }

    pub fn will_save(self: *Handler, alloc: Allocator, p: struct {
        file: []const u8,
    }) !ProcessResult {
        const lsp_ctx = switch (try self.getLspCtx(alloc, p.file)) {
            .ready => |c| c,
            .initializing, .not_available => return .{ .empty = {} },
        };

        var lsp_params = (try buildTextDocumentIdentifier(alloc, lsp_ctx.uri)).object;
        try lsp_params.put("reason", json.jsonInteger(1));

        lsp_ctx.client.sendNotification("textDocument/willSave", .{ .object = lsp_params }) catch |e| {
            log.err("Failed to send willSave: {any}", .{e});
        };

        return .{ .empty = {} };
    }

    // ========================================================================
    // Document highlight (LSP + tree-sitter fallback)
    // ========================================================================

    pub fn document_highlight(self: *Handler, alloc: Allocator, p: struct {
        file: []const u8,
        line: u32,
        column: u32,
        text: ?[]const u8 = null,
    }) !ProcessResult {
        // Try LSP first — it provides semantic scope awareness
        const lsp_result = try self.sendPositionRequest(alloc, p.file, p.line, p.column, "textDocument/documentHighlight");
        switch (lsp_result) {
            .pending_lsp => return lsp_result,
            .initializing => {},
            .empty => {},
            .data, .data_with_subscribe => return lsp_result,
        }

        // Fallback: tree-sitter based (textual match within scope)
        const tc = self.getTsCtx(p.file, p.text) orelse return .{ .empty = {} };
        const tree = tc.ts.getTree(tc.file) orelse return .{ .empty = {} };
        const source = tc.ts.getSource(tc.file) orelse return .{ .empty = {} };

        const result = try ts_mod.document_highlight.extractDocumentHighlights(
            alloc,
            tree,
            source,
            p.line,
            p.column,
        );
        return .{ .data = result };
    }

    // ========================================================================
    // Tree-sitter
    // ========================================================================

    pub fn load_language(self: *Handler, alloc: Allocator, p: struct {
        lang_dir: []const u8,
    }) !ProcessResult {
        const ts_state = self.ts;

        ts_state.loadFromDir(p.lang_dir);

        return .{ .data = try json.buildObject(alloc, .{
            .{ "ok", .{ .bool = true } },
        }) };
    }

    pub fn ts_symbols(self: *Handler, alloc: Allocator, p: struct {
        file: []const u8,
        text: ?[]const u8 = null,
    }) !ProcessResult {
        const tc = self.getTsCtx(p.file, p.text) orelse return .{ .empty = {} };
        const tree = tc.ts.getTree(tc.file) orelse return .{ .empty = {} };
        const source = tc.ts.getSource(tc.file) orelse return .{ .empty = {} };
        const sym_query = tc.lang_state.symbols orelse return .{ .empty = {} };

        const result = try ts_mod.symbols.extractSymbols(
            alloc,
            sym_query,
            tree,
            source,
            tc.file,
        );
        return .{ .data = result };
    }

    pub fn ts_folding(self: *Handler, alloc: Allocator, p: struct {
        file: []const u8,
        text: ?[]const u8 = null,
    }) !ProcessResult {
        const tc = self.getTsCtx(p.file, p.text) orelse return .{ .empty = {} };
        const tree = tc.ts.getTree(tc.file) orelse return .{ .empty = {} };
        const folds_query = tc.lang_state.folds orelse return .{ .empty = {} };

        const result = try ts_mod.folds.extractFolds(
            alloc,
            folds_query,
            tree,
        );
        return .{ .data = result };
    }

    pub fn ts_navigate(self: *Handler, alloc: Allocator, p: struct {
        file: []const u8,
        text: ?[]const u8 = null,
        target: []const u8 = "function",
        direction: []const u8 = "next",
        line: u32,
    }) !ProcessResult {
        const tc = self.getTsCtx(p.file, p.text) orelse return .{ .empty = {} };
        const tree = tc.ts.getTree(tc.file) orelse return .{ .empty = {} };
        const sym_query = tc.lang_state.symbols orelse return .{ .empty = {} };

        const result = try ts_mod.navigate.navigate(
            alloc,
            sym_query,
            tree,
            p.target,
            p.direction,
            p.line,
        );
        return .{ .data = result };
    }

    pub fn ts_textobjects(self: *Handler, alloc: Allocator, p: struct {
        file: []const u8,
        text: ?[]const u8 = null,
        target: []const u8,
        line: u32,
        column: u32,
    }) !ProcessResult {
        const tc = self.getTsCtx(p.file, p.text) orelse return .{ .empty = {} };
        const tree = tc.ts.getTree(tc.file) orelse return .{ .empty = {} };
        const to_query = tc.lang_state.textobjects orelse return .{ .empty = {} };

        const result = try ts_mod.textobjects.findTextObject(
            alloc,
            to_query,
            tree,
            p.target,
            p.line,
            p.column,
        );
        return .{ .data = result };
    }

    pub fn ts_highlights(self: *Handler, alloc: Allocator, p: struct {
        file: []const u8,
        text: ?[]const u8 = null,
        start_line: u32 = 0,
        end_line: u32 = 100,
    }) !ProcessResult {
        const tc = self.getTsCtx(p.file, p.text) orelse return .{ .empty = {} };
        const tree = tc.ts.getTree(tc.file) orelse return .{ .empty = {} };
        const source = tc.ts.getSource(tc.file) orelse return .{ .empty = {} };
        const hl_query = tc.lang_state.highlights orelse return .{ .empty = {} };

        var result = try ts_mod.highlights.extractHighlights(
            alloc,
            hl_query,
            tree,
            source,
            p.start_line,
            p.end_line,
        );

        if (tc.lang_state.injections) |inj_query| {
            try ts_mod.highlights.processInjections(
                alloc,
                inj_query,
                tree,
                source,
                p.start_line,
                p.end_line,
                tc.ts,
                &result,
            );
        }

        return .{ .data = result };
    }

    pub fn ts_hover_highlight(self: *Handler, alloc: Allocator, p: struct {
        markdown: []const u8,
        filetype: []const u8 = "",
    }) !ProcessResult {
        const ts_state = self.ts;

        const result = try ts_mod.hover_highlight.extractHoverHighlights(
            alloc,
            ts_state,
            p.markdown,
            p.filetype,
        );
        return .{ .data = result };
    }

    // ========================================================================
    // Picker
    // ========================================================================

    pub fn picker_open(_: *Handler, alloc: Allocator, p: struct {
        cwd: []const u8,
        recent_files: ?Value = null,
    }) !ProcessResult {
        var result = try json.buildObjectMap(alloc, .{
            .{ "action", json.jsonString("picker_init") },
            .{ "cwd", json.jsonString(p.cwd) },
        });
        if (p.recent_files) |rf| {
            try result.put("recent_files", rf);
        }

        return .{ .data = .{ .object = result } };
    }

    pub fn picker_query(self: *Handler, alloc: Allocator, p: struct {
        query: []const u8 = "",
        mode: []const u8 = "file",
        file: ?[]const u8 = null,
        text: ?[]const u8 = null,
    }) !ProcessResult {
        if (std.mem.eql(u8, p.mode, "workspace_symbol")) {
            const file = p.file orelse return .{ .empty = {} };
            const lsp_ctx = switch (try self.getLspCtx(alloc, file)) {
                .ready => |c| c,
                .initializing => return .{ .initializing = {} },
                .not_available => return .{ .empty = {} },
            };

            const ws_params = try json.buildObject(alloc, .{
                .{ "query", json.jsonString(p.query) },
            });
            const request_id = try lsp_ctx.client.sendRequest("workspace/symbol", ws_params);
            return .{ .pending_lsp = .{ .lsp_request_id = request_id } };
        } else if (std.mem.eql(u8, p.mode, "grep")) {
            return .{ .data = try json.buildObject(alloc, .{
                .{ "action", json.jsonString("picker_grep_query") },
                .{ "query", json.jsonString(p.query) },
            }) };
        } else if (std.mem.eql(u8, p.mode, "document_symbol")) {
            const ts_state = self.ts;
            const file = p.file orelse return .{ .empty = {} };
            const lang_state = ts_state.fromExtension(file) orelse return .{ .empty = {} };

            if (ts_state.getTree(file) == null) {
                if (p.text) |text| {
                    ts_state.parseBuffer(file, text) catch {};
                }
            }

            const tree = ts_state.getTree(file) orelse return .{ .empty = {} };
            const source = ts_state.getSource(file) orelse return .{ .empty = {} };
            const sym_query = lang_state.symbols orelse return .{ .empty = {} };

            const result = try ts_mod.symbols.extractPickerSymbols(
                alloc,
                sym_query,
                tree,
                source,
            );
            return .{ .data = result };
        } else {
            return .{ .data = try json.buildObject(alloc, .{
                .{ "action", json.jsonString("picker_file_query") },
                .{ "query", json.jsonString(p.query) },
            }) };
        }
    }

    pub fn picker_close(_: *Handler, alloc: Allocator) !ProcessResult {
        return .{ .data = try json.buildObject(alloc, .{
            .{ "action", json.jsonString("picker_close") },
        }) };
    }

    // ========================================================================
    // Copilot
    // ========================================================================

    pub fn copilot_sign_in(self: *Handler, alloc: Allocator) !ProcessResult {
        self.registry.resetCopilotSpawnFailed();
        const client = self.getCopilotClient(alloc) orelse return .{ .empty = {} };
        if (!self.copilotReady()) return .{ .initializing = {} };

        const request_id = try client.sendRequest("signIn", .{ .object = ObjectMap.init(alloc) });
        return .{ .pending_lsp = .{ .lsp_request_id = request_id, .client_key = LspRegistry.copilot_key } };
    }

    pub fn copilot_sign_out(self: *Handler, alloc: Allocator) !ProcessResult {
        const client = self.getCopilotClient(alloc) orelse return .{ .empty = {} };
        if (!self.copilotReady()) return .{ .initializing = {} };

        const request_id = try client.sendRequest("signOut", .{ .object = ObjectMap.init(alloc) });
        return .{ .pending_lsp = .{ .lsp_request_id = request_id, .client_key = LspRegistry.copilot_key } };
    }

    pub fn copilot_check_status(self: *Handler, alloc: Allocator) !ProcessResult {
        const client = self.getCopilotClient(alloc) orelse return .{ .empty = {} };
        if (!self.copilotReady()) return .{ .initializing = {} };

        const request_id = try client.sendRequest("checkStatus", .{ .object = ObjectMap.init(alloc) });
        return .{ .pending_lsp = .{ .lsp_request_id = request_id, .client_key = LspRegistry.copilot_key } };
    }

    pub fn copilot_sign_in_confirm(self: *Handler, alloc: Allocator, p: struct {
        userCode: ?[]const u8 = null,
    }) !ProcessResult {
        const client = self.getCopilotClient(alloc) orelse return .{ .empty = {} };
        if (!self.copilotReady()) return .{ .initializing = {} };

        var confirm_params = ObjectMap.init(alloc);
        if (p.userCode) |code| {
            try confirm_params.put("userCode", json.jsonString(code));
        }

        const request_id = try client.sendRequest("signInConfirm", .{ .object = confirm_params });
        return .{ .pending_lsp = .{ .lsp_request_id = request_id, .client_key = LspRegistry.copilot_key } };
    }

    pub fn copilot_complete(self: *Handler, alloc: Allocator, p: struct {
        file: []const u8,
        line: u32,
        column: u32,
        tab_size: i64 = 4,
        insert_spaces: bool = true,
    }) !ProcessResult {
        const client = self.getCopilotClient(alloc) orelse return .{ .empty = {} };
        if (!self.copilotReady()) return .{ .initializing = {} };

        self.ensureCopilotDidOpen(alloc, client, p.file);

        const uri = try lsp_registry_mod.filePathToUri(alloc, lsp_registry_mod.extractRealPath(p.file));

        const lsp_params = try json.buildObject(alloc, .{
            .{ "textDocument", try json.buildObject(alloc, .{
                .{ "uri", json.jsonString(uri) },
            }) },
            .{ "position", try json.buildObject(alloc, .{
                .{ "line", json.jsonInteger(@intCast(p.line)) },
                .{ "character", json.jsonInteger(@intCast(p.column)) },
            }) },
            .{ "context", try json.buildObject(alloc, .{
                .{ "triggerKind", json.jsonInteger(1) },
            }) },
            .{ "formattingOptions", try json.buildObject(alloc, .{
                .{ "tabSize", json.jsonInteger(p.tab_size) },
                .{ "insertSpaces", json.jsonBool(p.insert_spaces) },
            }) },
        });

        const request_id = try client.sendRequest("textDocument/inlineCompletion", lsp_params);
        return .{ .pending_lsp = .{ .lsp_request_id = request_id, .client_key = LspRegistry.copilot_key } };
    }

    pub fn copilot_did_focus(self: *Handler, alloc: Allocator, p: struct {
        file: []const u8,
    }) !ProcessResult {
        const client = self.registry.copilot_client orelse return .{ .empty = {} };
        if (!self.copilotReady()) return .{ .empty = {} };

        const uri = try lsp_registry_mod.filePathToUri(alloc, lsp_registry_mod.extractRealPath(p.file));

        const notify_params = try json.buildObject(alloc, .{
            .{ "textDocument", try json.buildObject(alloc, .{
                .{ "uri", json.jsonString(uri) },
            }) },
        });

        client.sendNotification("textDocument/didFocus", notify_params) catch |e| {
            log.err("Failed to send didFocus to Copilot: {any}", .{e});
        };

        return .{ .empty = {} };
    }

    pub fn copilot_accept(self: *Handler, alloc: Allocator, p: struct {
        uuid: ?Value = null,
    }) !ProcessResult {
        const client = self.registry.copilot_client orelse return .{ .empty = {} };
        if (!self.copilotReady()) return .{ .empty = {} };

        var args = std.json.Array.init(alloc);
        if (p.uuid) |uuid| {
            try args.append(uuid);
        }

        const cmd_params = try json.buildObject(alloc, .{
            .{ "command", json.jsonString("github.copilot.didAcceptCompletionItem") },
            .{ "arguments", .{ .array = args } },
        });

        client.sendNotification("workspace/executeCommand", cmd_params) catch |e| {
            log.err("Failed to send Copilot accept: {any}", .{e});
        };

        return .{ .empty = {} };
    }

    pub fn copilot_partial_accept(self: *Handler, alloc: Allocator, p: struct {
        item_id: ?[]const u8 = null,
        accepted_text: ?[]const u8 = null,
    }) !ProcessResult {
        const client = self.registry.copilot_client orelse return .{ .empty = {} };
        if (!self.copilotReady()) return .{ .empty = {} };

        var notify_params = ObjectMap.init(alloc);
        if (p.item_id) |id| {
            try notify_params.put("itemId", json.jsonString(id));
        }
        if (p.accepted_text) |text| {
            try notify_params.put("acceptedLength", json.jsonInteger(@intCast(text.len)));
        }

        client.sendNotification("textDocument/didPartiallyAcceptCompletion", .{ .object = notify_params }) catch |e| {
            log.err("Failed to send Copilot partial accept: {any}", .{e});
        };

        return .{ .empty = {} };
    }

    // ========================================================================
    // DAP
    // ========================================================================

    pub fn dap_load_config(self: *Handler, alloc: Allocator, p: struct {
        project_root: []const u8,
        file: []const u8 = "",
        dirname: []const u8 = "",
    }) !ProcessResult {
        const result = dap_config.loadDebugConfig(alloc, p.project_root, p.file, p.dirname) catch |e| {
            log.err("handleDapLoadConfig: loadDebugConfig failed: {any}", .{e});
            try self.sendEmptyConfigs(alloc);
            return .{ .empty = {} };
        };

        if (result) |configs| {
            var args_array = std.json.Array.init(alloc);
            try args_array.append(configs);
            try self.vimCallAsync(alloc, "yac_dap#on_debug_configs", .{ .array = args_array });
        } else {
            try self.sendEmptyConfigs(alloc);
        }

        return .{ .empty = {} };
    }

    pub fn dap_start(self: *Handler, alloc: Allocator, p: struct {
        file: []const u8,
        program: ?[]const u8 = null,
        adapter_command: ?[]const u8 = null,
        adapter_args: ?Value = null,
        breakpoints: ?Value = null,
        args: ?Value = null,
        stop_on_entry: ?Value = null,
        module: ?[]const u8 = null,
        cwd: ?[]const u8 = null,
        env: ?Value = null,
        extra: ?Value = null,
        request: ?[]const u8 = null,
        pid: ?u32 = null,
    }) !ProcessResult {
        log.debug("handleDapStart: entered", .{});
        const ext = std.fs.path.extension(p.file);
        const config = dap_config.findByExtension(ext) orelse {
            const msg = std.fmt.allocPrint(alloc, "call yac#toast('[yac] No debug adapter for {s} files')", .{ext}) catch return .{ .empty = {} };
            try self.vimEx(alloc, msg);
            return .{ .empty = {} };
        };

        const command = p.adapter_command orelse config.command;

        var user_args: std.ArrayList([]const u8) = .{};
        defer user_args.deinit(alloc);
        if (p.adapter_args) |aa| {
            if (aa == .array) {
                for (aa.array.items) |item| {
                    if (item == .string) {
                        user_args.append(alloc, item.string) catch continue;
                    }
                }
            }
        }
        const args: []const []const u8 = if (user_args.items.len > 0) user_args.items else config.args;

        const workspace_dir = std.fs.path.dirname(p.file);

        if (self.dap_session.*) |old| {
            _ = old.client.sendDisconnect(true) catch 0;
            old.client.deinit();
            old.deinit();
            self.gpa.destroy(old);
            self.dap_session.* = null;
        }

        const client = DapClient.spawn(self.gpa, command, args, workspace_dir) catch |e| {
            log.err("Failed to spawn DAP adapter '{s}': {any}", .{ command, e });
            const msg = std.fmt.allocPrint(alloc, "call yac#toast('[yac] Failed to start debug adapter: {s}')", .{command}) catch return .{ .empty = {} };
            try self.vimEx(alloc, msg);
            return .{ .empty = {} };
        };

        const session = self.gpa.create(DapSession) catch {
            client.deinit();
            return .{ .empty = {} };
        };
        session.* = DapSession.init(self.gpa, client);
        session.session_state = .initializing;
        session.owner_client_id = self.client_id;
        self.dap_session.* = session;

        const program_raw = p.program orelse p.file;
        const program = self.gpa.dupe(u8, program_raw) catch return .{ .empty = {} };
        const stop_on_entry = if (p.stop_on_entry) |v| switch (v) {
            .bool => |b| b,
            .integer => |i| i != 0,
            else => false,
        } else false;

        var bp_files = std.StringArrayHashMap(std.ArrayList(u32)).init(self.gpa);
        if (p.breakpoints) |bp_val| {
            if (bp_val == .array) {
                for (bp_val.array.items) |item| {
                    const bp_obj = switch (item) {
                        .object => |o| o,
                        else => continue,
                    };
                    const bp_file_raw = json.getString(bp_obj, "file") orelse continue;
                    const bp_line = json.getU32(bp_obj, "line") orelse continue;

                    const bp_file = self.gpa.dupe(u8, bp_file_raw) catch continue;
                    const gop = bp_files.getOrPut(bp_file) catch {
                        self.gpa.free(bp_file);
                        continue;
                    };
                    if (!gop.found_existing) {
                        gop.value_ptr.* = .{};
                    } else {
                        self.gpa.free(bp_file);
                    }
                    gop.value_ptr.append(self.gpa, bp_line) catch continue;
                }
            }
        }

        var launch_args: std.ArrayList([]const u8) = .{};
        if (p.args) |args_val| {
            if (args_val == .array) {
                for (args_val.array.items) |item| {
                    const s = switch (item) {
                        .string => |str| str,
                        else => continue,
                    };
                    const duped = self.gpa.dupe(u8, s) catch continue;
                    launch_args.append(self.gpa, duped) catch {
                        self.gpa.free(duped);
                        continue;
                    };
                }
            }
        }

        const module: ?[]const u8 = if (p.module) |m|
            self.gpa.dupe(u8, m) catch null
        else
            null;

        const cwd: ?[]const u8 = if (p.cwd) |c|
            self.gpa.dupe(u8, c) catch null
        else
            null;

        const env_json: ?[]const u8 = if (p.env) |env_val|
            (if (env_val == .object) json.stringifyAlloc(self.gpa, env_val) catch null else null)
        else
            null;

        const extra_json: ?[]const u8 = if (p.extra) |extra_val|
            (if (extra_val == .object) json.stringifyAlloc(self.gpa, extra_val) catch null else null)
        else
            null;

        const request_type: dap_client_mod.RequestType = if (p.request) |req_str|
            (if (std.mem.eql(u8, req_str, "attach")) .attach else .launch)
        else
            .launch;

        client.launch_params = .{
            .program = program,
            .module = module,
            .stop_on_entry = stop_on_entry,
            .breakpoint_files = bp_files,
            .args = launch_args,
            .cwd = cwd,
            .env_json = env_json,
            .extra_json = extra_json,
            .request_type = request_type,
            .pid = p.pid,
        };

        _ = client.initialize() catch |e| {
            log.err("DAP initialize failed: {any}", .{e});
            return .{ .empty = {} };
        };

        log.info("DAP session starting for {s} ({s})", .{ p.file, config.language_id });

        return .{ .data = try json.buildObject(alloc, .{
            .{ "status", json.jsonString("initializing") },
            .{ "adapter", json.jsonString(command) },
        }) };
    }

    pub fn dap_breakpoint(self: *Handler, alloc: Allocator, p: struct {
        file: []const u8,
        breakpoints: ?Value = null,
    }) !ProcessResult {
        const session = self.dap_session.* orelse return self.notRunning(alloc);

        const bp_array = if (p.breakpoints) |bp_val| switch (bp_val) {
            .array => |a| a,
            else => return .{ .empty = {} },
        } else return .{ .empty = {} };

        var breakpoints: std.ArrayList(dap_client_mod.BreakpointInfo) = .{};
        defer breakpoints.deinit(alloc);
        for (bp_array.items) |item| {
            const bp_obj = switch (item) {
                .object => |o| o,
                else => continue,
            };
            if (json.getU32(bp_obj, "line")) |line| {
                try breakpoints.append(alloc, .{
                    .line = line,
                    .condition = json.getString(bp_obj, "condition"),
                    .hit_condition = json.getString(bp_obj, "hit_condition"),
                    .log_message = json.getString(bp_obj, "log_message"),
                });
            }
        }

        _ = try session.client.sendSetBreakpoints(alloc, p.file, breakpoints.items);
        return .{ .data = try json.buildObject(alloc, .{
            .{ "ok", .{ .bool = true } },
        }) };
    }

    pub fn dap_exception_breakpoints(self: *Handler, alloc: Allocator, p: struct {
        filters: ?Value = null,
    }) !ProcessResult {
        const session = self.dap_session.* orelse return self.notRunning(alloc);

        const filters_val = if (p.filters) |f| switch (f) {
            .array => |a| a,
            else => return .{ .empty = {} },
        } else return .{ .empty = {} };

        var filters: std.ArrayList([]const u8) = .{};
        defer filters.deinit(alloc);
        for (filters_val.items) |item| {
            switch (item) {
                .string => |s| try filters.append(alloc, s),
                else => {},
            }
        }

        _ = try session.client.sendSetExceptionBreakpoints(alloc, filters.items);
        return .{ .data = try json.buildObject(alloc, .{
            .{ "ok", .{ .bool = true } },
        }) };
    }

    pub fn dap_threads(self: *Handler, alloc: Allocator) !ProcessResult {
        const session = self.dap_session.* orelse return self.notRunning(alloc);
        _ = try session.client.sendThreads();
        return .{ .data = try json.buildObject(alloc, .{
            .{ "pending", .{ .bool = true } },
        }) };
    }

    pub fn dap_continue(self: *Handler, alloc: Allocator, p: struct {
        thread_id: ?u32 = null,
    }) !ProcessResult {
        return self.handleThreadControl(alloc, p.thread_id, DapClient.sendContinue);
    }

    pub fn dap_next(self: *Handler, alloc: Allocator, p: struct {
        thread_id: ?u32 = null,
    }) !ProcessResult {
        return self.handleThreadControl(alloc, p.thread_id, DapClient.sendNext);
    }

    pub fn dap_step_in(self: *Handler, alloc: Allocator, p: struct {
        thread_id: ?u32 = null,
    }) !ProcessResult {
        return self.handleThreadControl(alloc, p.thread_id, DapClient.sendStepIn);
    }

    pub fn dap_step_out(self: *Handler, alloc: Allocator, p: struct {
        thread_id: ?u32 = null,
    }) !ProcessResult {
        return self.handleThreadControl(alloc, p.thread_id, DapClient.sendStepOut);
    }

    pub fn dap_stack_trace(self: *Handler, alloc: Allocator, p: struct {
        thread_id: ?u32 = null,
    }) !ProcessResult {
        const session = self.dap_session.* orelse return self.notRunning(alloc);

        const thread_id = p.thread_id orelse session.client.active_thread_id orelse 1;
        _ = try session.client.sendStackTrace(thread_id);
        return .{ .data = try json.buildObject(alloc, .{
            .{ "pending", .{ .bool = true } },
        }) };
    }

    pub fn dap_scopes(self: *Handler, alloc: Allocator, p: struct {
        frame_id: u32,
    }) !ProcessResult {
        const session = self.dap_session.* orelse return self.notRunning(alloc);

        _ = try session.client.sendScopes(p.frame_id);
        return .{ .data = try json.buildObject(alloc, .{
            .{ "pending", .{ .bool = true } },
        }) };
    }

    pub fn dap_variables(self: *Handler, alloc: Allocator, p: struct {
        variables_ref: u32,
    }) !ProcessResult {
        const session = self.dap_session.* orelse return self.notRunning(alloc);

        _ = try session.client.sendVariables(p.variables_ref);
        return .{ .data = try json.buildObject(alloc, .{
            .{ "pending", .{ .bool = true } },
        }) };
    }

    pub fn dap_evaluate(self: *Handler, alloc: Allocator, p: struct {
        expression: []const u8,
        frame_id: ?u32 = null,
        context: []const u8 = "repl",
    }) !ProcessResult {
        const session = self.dap_session.* orelse return self.notRunning(alloc);

        _ = try session.client.sendEvaluate(p.expression, p.frame_id, p.context);
        return .{ .data = try json.buildObject(alloc, .{
            .{ "pending", .{ .bool = true } },
        }) };
    }

    pub fn dap_terminate(self: *Handler, alloc: Allocator) !ProcessResult {
        const session = self.dap_session.* orelse return self.notRunning(alloc);
        _ = session.client.sendTerminate() catch {};
        _ = session.client.sendDisconnect(true) catch {};
        return .{ .data = try json.buildObject(alloc, .{
            .{ "ok", .{ .bool = true } },
        }) };
    }

    pub fn dap_status(self: *Handler, alloc: Allocator) !ProcessResult {
        const session = self.dap_session.* orelse {
            return .{ .data = try json.buildObject(alloc, .{
                .{ "active", .{ .bool = false } },
            }) };
        };

        return .{ .data = try session.buildPanelData(alloc) };
    }

    pub fn dap_get_panel(self: *Handler, alloc: Allocator) !ProcessResult {
        const session = self.dap_session.* orelse return self.notRunning(alloc);
        return .{ .data = try session.buildPanelData(alloc) };
    }

    pub fn dap_switch_frame(self: *Handler, alloc: Allocator, p: struct {
        frame_index: u32,
    }) !ProcessResult {
        const session = self.dap_session.* orelse return self.notRunning(alloc);

        session.switchFrame(p.frame_index) catch |e| {
            log.err("DAP switchFrame failed: {any}", .{e});
            return .{ .empty = {} };
        };
        return .{ .data = try json.buildObject(alloc, .{
            .{ "ok", .{ .bool = true } },
        }) };
    }

    pub fn dap_expand_variable(self: *Handler, alloc: Allocator, p: struct {
        path: ?Value = null,
    }) !ProcessResult {
        const session = self.dap_session.* orelse return self.notRunning(alloc);
        const path = try parsePathFromValue(alloc, p.path) orelse return .{ .empty = {} };
        defer alloc.free(path);

        session.expandVariable(path) catch |e| {
            log.err("DAP expandVariable failed: {any}", .{e});
            return .{ .empty = {} };
        };
        return .{ .data = try json.buildObject(alloc, .{
            .{ "ok", .{ .bool = true } },
        }) };
    }

    pub fn dap_collapse_variable(self: *Handler, alloc: Allocator, p: struct {
        path: ?Value = null,
    }) !ProcessResult {
        const session = self.dap_session.* orelse return self.notRunning(alloc);
        const path = try parsePathFromValue(alloc, p.path) orelse return .{ .empty = {} };
        defer alloc.free(path);

        session.collapseVariable(path);
        return .{ .data = try json.buildObject(alloc, .{
            .{ "ok", .{ .bool = true } },
        }) };
    }

    pub fn dap_add_watch(self: *Handler, alloc: Allocator, p: struct {
        expression: []const u8,
    }) !ProcessResult {
        const session = self.dap_session.* orelse return self.notRunning(alloc);

        try session.addWatch(p.expression);
        return .{ .data = try json.buildObject(alloc, .{
            .{ "ok", .{ .bool = true } },
        }) };
    }

    pub fn dap_remove_watch(self: *Handler, alloc: Allocator, p: struct {
        index: u32,
    }) !ProcessResult {
        const session = self.dap_session.* orelse return self.notRunning(alloc);

        session.removeWatch(p.index);
        return .{ .data = try json.buildObject(alloc, .{
            .{ "ok", .{ .bool = true } },
        }) };
    }
};
