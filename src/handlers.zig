const std = @import("std");
const json = @import("json_utils.zig");
const vim = @import("vim_protocol.zig");
const registry_mod = @import("lsp_registry.zig");
const LspClient = @import("lsp_client.zig").LspClient;
const log = @import("log.zig");

const Allocator = std.mem.Allocator;
const Value = json.Value;
const ObjectMap = json.ObjectMap;
const LspRegistry = registry_mod.LspRegistry;

// ============================================================================
// Handler Context - what every handler receives
// ============================================================================

pub const HandlerContext = struct {
    allocator: Allocator,
    registry: *LspRegistry,
    vim_writer: std.fs.File.Writer,
};

/// Result of dispatching a handler.
pub const DispatchResult = union(enum) {
    /// Handler produced a direct response value.
    data: Value,
    /// Handler produced nothing (e.g., goto found nothing).
    empty: void,
    /// Handler sent an LSP request and is waiting for a response.
    pending_lsp: struct {
        lsp_request_id: u32,
    },
    /// LSP client is still initializing; caller should defer and retry.
    initializing: void,
};

// ============================================================================
// Handler Dispatch Table
//
// Comptime inline for: zero runtime overhead, no vtable.
// ============================================================================

pub const Handler = struct {
    name: []const u8,
    handleFn: *const fn (*HandlerContext, Value) anyerror!DispatchResult,
};

pub const handlers = [_]Handler{
    .{ .name = "file_open", .handleFn = handleFileOpen },
    .{ .name = "goto_definition", .handleFn = handleGotoDefinition },
    .{ .name = "goto_declaration", .handleFn = handleGotoDeclaration },
    .{ .name = "goto_type_definition", .handleFn = handleGotoTypeDefinition },
    .{ .name = "goto_implementation", .handleFn = handleGotoImplementation },
    .{ .name = "hover", .handleFn = handleHover },
    .{ .name = "completion", .handleFn = handleCompletion },
    .{ .name = "references", .handleFn = handleReferences },
    .{ .name = "rename", .handleFn = handleRename },
    .{ .name = "code_action", .handleFn = handleCodeAction },
    .{ .name = "document_symbols", .handleFn = handleDocumentSymbols },
    .{ .name = "diagnostics", .handleFn = handleDiagnostics },
    .{ .name = "did_change", .handleFn = handleDidChange },
    .{ .name = "did_save", .handleFn = handleDidSave },
    .{ .name = "did_close", .handleFn = handleDidClose },
    .{ .name = "will_save", .handleFn = handleWillSave },
    .{ .name = "inlay_hints", .handleFn = handleInlayHints },
    .{ .name = "folding_range", .handleFn = handleFoldingRange },
    .{ .name = "call_hierarchy", .handleFn = handleCallHierarchy },
    .{ .name = "execute_command", .handleFn = handleExecuteCommand },
};

pub fn dispatch(ctx: *HandlerContext, method: []const u8, params: Value) !DispatchResult {
    inline for (handlers) |h| {
        if (std.mem.eql(u8, method, h.name)) {
            return h.handleFn(ctx, params);
        }
    }
    log.warn("Unknown method: {s}", .{method});
    return .{ .empty = {} };
}

// ============================================================================
// Helper: extract file/line/column, detect language, get LSP client
// ============================================================================

const LspContext = struct {
    language: []const u8,
    client_key: []const u8,
    uri: []const u8,
    client: *LspClient,
    ssh_host: ?[]const u8,
    real_path: []const u8,
};

/// Result of trying to get LSP context.
const LspContextResult = union(enum) {
    /// Context is ready.
    ready: LspContext,
    /// Client is still initializing (caller should defer).
    initializing: void,
    /// No context available (unsupported language, bad params, etc.).
    not_available: void,
};

/// Get LSP context for a request.
fn getLspContext(ctx: *HandlerContext, params: Value) !LspContextResult {
    return getLspContextEx(ctx, params, true);
}

/// Get LSP context, optionally allowing initializing clients (for handleFileOpen).
fn getLspContextEx(ctx: *HandlerContext, params: Value, require_ready: bool) !LspContextResult {
    const obj = switch (params) {
        .object => |o| o,
        else => return .{ .not_available = {} },
    };

    const file = json.getString(obj, "file") orelse return .{ .not_available = {} };
    const real_path = registry_mod.extractRealPath(file);
    const ssh_host = registry_mod.extractSshHost(file);

    const language = LspRegistry.detectLanguage(real_path) orelse {
        log.debug("No language detected for {s}", .{real_path});
        return .{ .not_available = {} };
    };

    const result = ctx.registry.getOrCreateClient(language, real_path) catch |e| {
        log.err("Failed to get LSP client for {s}: {any}", .{ language, e });
        // Notify user once per language when LSP server cannot be started
        if (!ctx.registry.hasSpawnFailed(language)) {
            ctx.registry.markSpawnFailed(language);
            const config = LspRegistry.getConfig(language);
            const cmd = if (config) |c| c.command else language;
            const msg = std.fmt.allocPrint(ctx.allocator, "echoerr '[yac] LSP server \"{s}\" not found. Please install it for {s} support.'", .{ cmd, language }) catch {
                return .{ .not_available = {} };
            };
            vimEx(ctx, msg) catch {};
        }
        return .{ .not_available = {} };
    };

    if (require_ready and ctx.registry.isInitializing(result.client_key)) return .{ .initializing = {} };

    const uri = try registry_mod.filePathToUri(ctx.allocator, real_path);

    return .{ .ready = .{
        .language = language,
        .client_key = result.client_key,
        .uri = uri,
        .client = result.client,
        .ssh_host = ssh_host,
        .real_path = real_path,
    } };
}

/// Build textDocument/position params for LSP.
fn buildTextDocumentPosition(allocator: Allocator, uri: []const u8, line: u32, column: u32) !Value {
    var td = ObjectMap.init(allocator);
    try td.put("uri", json.jsonString(uri));

    var pos = ObjectMap.init(allocator);
    try pos.put("line", json.jsonInteger(@intCast(line)));
    try pos.put("character", json.jsonInteger(@intCast(column)));

    var params = ObjectMap.init(allocator);
    try params.put("textDocument", .{ .object = td });
    try params.put("position", .{ .object = pos });
    return .{ .object = params };
}

/// Build textDocument identifier params for LSP.
fn buildTextDocumentIdentifier(allocator: Allocator, uri: []const u8) !Value {
    var td = ObjectMap.init(allocator);
    try td.put("uri", json.jsonString(uri));

    var params = ObjectMap.init(allocator);
    try params.put("textDocument", .{ .object = td });
    return .{ .object = params };
}

/// Send a Vim ex command.
fn vimEx(ctx: *HandlerContext, command: []const u8) !void {
    const encoded = try vim.encodeChannelCommand(ctx.allocator, .{ .ex = .{ .command = command } });
    defer ctx.allocator.free(encoded);
    try ctx.vim_writer.print("{s}\n", .{encoded});
}

/// Send a Vim call_async command.
fn vimCallAsync(ctx: *HandlerContext, func: []const u8, args: Value) !void {
    const encoded = try vim.encodeChannelCommand(ctx.allocator, .{ .call_async = .{
        .func = func,
        .args = args,
    } });
    defer ctx.allocator.free(encoded);
    try ctx.vim_writer.print("{s}\n", .{encoded});
}

// ============================================================================
// Handler Implementations
// ============================================================================

fn handleFileOpen(ctx: *HandlerContext, params: Value) !DispatchResult {
    const lsp_ctx = switch (try getLspContextEx(ctx, params, false)) {
        .ready => |c| c,
        .initializing, .not_available => return .{ .empty = {} },
    };

    // Read file content
    const content = std.fs.cwd().readFileAlloc(ctx.allocator, lsp_ctx.real_path, 10 * 1024 * 1024) catch |e| {
        log.err("Failed to read file {s}: {any}", .{ lsp_ctx.real_path, e });
        return .{ .empty = {} };
    };

    if (ctx.registry.isInitializing(lsp_ctx.client_key)) {
        // Queue for replay after initialization completes
        ctx.registry.queuePendingOpen(lsp_ctx.client_key, lsp_ctx.uri, lsp_ctx.language, content) catch |e| {
            log.err("Failed to queue pending open: {any}", .{e});
        };
    } else {
        // Send didOpen now
        var td_item = ObjectMap.init(ctx.allocator);
        try td_item.put("uri", json.jsonString(lsp_ctx.uri));
        try td_item.put("languageId", json.jsonString(lsp_ctx.language));
        try td_item.put("version", json.jsonInteger(1));
        try td_item.put("text", json.jsonString(content));

        var did_open_params = ObjectMap.init(ctx.allocator);
        try did_open_params.put("textDocument", .{ .object = td_item });

        lsp_ctx.client.sendNotification("textDocument/didOpen", .{ .object = did_open_params }) catch |e| {
            log.err("Failed to send didOpen: {any}", .{e});
        };
    }

    var response = ObjectMap.init(ctx.allocator);
    try response.put("action", json.jsonString("none"));
    return .{ .data = .{ .object = response } };
}

fn handleGoto(ctx: *HandlerContext, params: Value, lsp_method: []const u8) !DispatchResult {
    const lsp_ctx = switch (try getLspContext(ctx, params)) {
        .ready => |c| c,
        .initializing => return .{ .initializing = {} },
        .not_available => return .{ .empty = {} },
    };

    const obj = switch (params) {
        .object => |o| o,
        else => return .{ .empty = {} },
    };

    const line: u32 = @intCast(json.getInteger(obj, "line") orelse return .{ .empty = {} });
    const column: u32 = @intCast(json.getInteger(obj, "column") orelse return .{ .empty = {} });

    const lsp_params = try buildTextDocumentPosition(ctx.allocator, lsp_ctx.uri, line, column);
    const request_id = try lsp_ctx.client.sendRequest(lsp_method, lsp_params);

    return .{ .pending_lsp = .{ .lsp_request_id = request_id } };
}

fn handleGotoDefinition(ctx: *HandlerContext, params: Value) !DispatchResult {
    return handleGoto(ctx, params, "textDocument/definition");
}

fn handleGotoDeclaration(ctx: *HandlerContext, params: Value) !DispatchResult {
    return handleGoto(ctx, params, "textDocument/declaration");
}

fn handleGotoTypeDefinition(ctx: *HandlerContext, params: Value) !DispatchResult {
    return handleGoto(ctx, params, "textDocument/typeDefinition");
}

fn handleGotoImplementation(ctx: *HandlerContext, params: Value) !DispatchResult {
    return handleGoto(ctx, params, "textDocument/implementation");
}

fn handleHover(ctx: *HandlerContext, params: Value) !DispatchResult {
    const lsp_ctx = switch (try getLspContext(ctx, params)) {
        .ready => |c| c,
        .initializing => return .{ .initializing = {} },
        .not_available => return .{ .empty = {} },
    };

const obj = switch (params) {
        .object => |o| o,
        else => return .{ .empty = {} },
    };

    const line: u32 = @intCast(json.getInteger(obj, "line") orelse return .{ .empty = {} });
    const column: u32 = @intCast(json.getInteger(obj, "column") orelse return .{ .empty = {} });

    const lsp_params = try buildTextDocumentPosition(ctx.allocator, lsp_ctx.uri, line, column);
    const request_id = try lsp_ctx.client.sendRequest("textDocument/hover", lsp_params);

    return .{ .pending_lsp = .{ .lsp_request_id = request_id } };
}

fn handleCompletion(ctx: *HandlerContext, params: Value) !DispatchResult {
    const lsp_ctx = switch (try getLspContext(ctx, params)) {
        .ready => |c| c,
        .initializing => return .{ .initializing = {} },
        .not_available => return .{ .empty = {} },
    };

const obj = switch (params) {
        .object => |o| o,
        else => return .{ .empty = {} },
    };

    const line: u32 = @intCast(json.getInteger(obj, "line") orelse return .{ .empty = {} });
    const column: u32 = @intCast(json.getInteger(obj, "column") orelse return .{ .empty = {} });

    const lsp_params = try buildTextDocumentPosition(ctx.allocator, lsp_ctx.uri, line, column);
    const request_id = try lsp_ctx.client.sendRequest("textDocument/completion", lsp_params);

    return .{ .pending_lsp = .{ .lsp_request_id = request_id } };
}

fn handleReferences(ctx: *HandlerContext, params: Value) !DispatchResult {
    const lsp_ctx = switch (try getLspContext(ctx, params)) {
        .ready => |c| c,
        .initializing => return .{ .initializing = {} },
        .not_available => return .{ .empty = {} },
    };

const obj = switch (params) {
        .object => |o| o,
        else => return .{ .empty = {} },
    };

    const line: u32 = @intCast(json.getInteger(obj, "line") orelse return .{ .empty = {} });
    const column: u32 = @intCast(json.getInteger(obj, "column") orelse return .{ .empty = {} });

    // Build references params (includes context.includeDeclaration)
    var lsp_params_obj = switch (try buildTextDocumentPosition(ctx.allocator, lsp_ctx.uri, line, column)) {
        .object => |o| o,
        else => unreachable,
    };

    var context_obj = ObjectMap.init(ctx.allocator);
    try context_obj.put("includeDeclaration", json.jsonBool(true));
    try lsp_params_obj.put("context", .{ .object = context_obj });

    const request_id = try lsp_ctx.client.sendRequest("textDocument/references", .{ .object = lsp_params_obj });

    return .{ .pending_lsp = .{ .lsp_request_id = request_id } };
}

fn handleRename(ctx: *HandlerContext, params: Value) !DispatchResult {
    const lsp_ctx = switch (try getLspContext(ctx, params)) {
        .ready => |c| c,
        .initializing => return .{ .initializing = {} },
        .not_available => return .{ .empty = {} },
    };

const obj = switch (params) {
        .object => |o| o,
        else => return .{ .empty = {} },
    };

    const line: u32 = @intCast(json.getInteger(obj, "line") orelse return .{ .empty = {} });
    const column: u32 = @intCast(json.getInteger(obj, "column") orelse return .{ .empty = {} });
    const new_name = json.getString(obj, "new_name") orelse return .{ .empty = {} };

    var lsp_params_obj = switch (try buildTextDocumentPosition(ctx.allocator, lsp_ctx.uri, line, column)) {
        .object => |o| o,
        else => unreachable,
    };
    try lsp_params_obj.put("newName", json.jsonString(new_name));

    const request_id = try lsp_ctx.client.sendRequest("textDocument/rename", .{ .object = lsp_params_obj });

    return .{ .pending_lsp = .{ .lsp_request_id = request_id } };
}

fn handleCodeAction(ctx: *HandlerContext, params: Value) !DispatchResult {
    const lsp_ctx = switch (try getLspContext(ctx, params)) {
        .ready => |c| c,
        .initializing => return .{ .initializing = {} },
        .not_available => return .{ .empty = {} },
    };

const obj = switch (params) {
        .object => |o| o,
        else => return .{ .empty = {} },
    };

    const line: u32 = @intCast(json.getInteger(obj, "line") orelse return .{ .empty = {} });
    const column: u32 = @intCast(json.getInteger(obj, "column") orelse return .{ .empty = {} });

    // Build code action params with range
    var td = ObjectMap.init(ctx.allocator);
    try td.put("uri", json.jsonString(lsp_ctx.uri));

    var start = ObjectMap.init(ctx.allocator);
    try start.put("line", json.jsonInteger(@intCast(line)));
    try start.put("character", json.jsonInteger(@intCast(column)));

    var end = ObjectMap.init(ctx.allocator);
    try end.put("line", json.jsonInteger(@intCast(line)));
    try end.put("character", json.jsonInteger(@intCast(column)));

    var range = ObjectMap.init(ctx.allocator);
    try range.put("start", .{ .object = start });
    try range.put("end", .{ .object = end });

    var context_obj = ObjectMap.init(ctx.allocator);
    var diag_array = std.json.Array.init(ctx.allocator);
    _ = &diag_array;
    try context_obj.put("diagnostics", .{ .array = diag_array });

    var lsp_params = ObjectMap.init(ctx.allocator);
    try lsp_params.put("textDocument", .{ .object = td });
    try lsp_params.put("range", .{ .object = range });
    try lsp_params.put("context", .{ .object = context_obj });

    const request_id = try lsp_ctx.client.sendRequest("textDocument/codeAction", .{ .object = lsp_params });

    return .{ .pending_lsp = .{ .lsp_request_id = request_id } };
}

fn handleDocumentSymbols(ctx: *HandlerContext, params: Value) !DispatchResult {
    const lsp_ctx = switch (try getLspContext(ctx, params)) {
        .ready => |c| c,
        .initializing => return .{ .initializing = {} },
        .not_available => return .{ .empty = {} },
    };

const lsp_params = try buildTextDocumentIdentifier(ctx.allocator, lsp_ctx.uri);
    const request_id = try lsp_ctx.client.sendRequest("textDocument/documentSymbol", lsp_params);

    return .{ .pending_lsp = .{ .lsp_request_id = request_id } };
}

fn handleDiagnostics(_: *HandlerContext, _: Value) !DispatchResult {
    // Diagnostics are pushed by the server via notifications, not pulled.
    return .{ .empty = {} };
}

fn handleInlayHints(ctx: *HandlerContext, params: Value) !DispatchResult {
    const lsp_ctx = switch (try getLspContext(ctx, params)) {
        .ready => |c| c,
        .initializing => return .{ .initializing = {} },
        .not_available => return .{ .empty = {} },
    };

const obj = switch (params) {
        .object => |o| o,
        else => return .{ .empty = {} },
    };

    const start_line: u32 = @intCast(json.getInteger(obj, "start_line") orelse 0);
    const end_line: u32 = @intCast(json.getInteger(obj, "end_line") orelse 100);

    var td = ObjectMap.init(ctx.allocator);
    try td.put("uri", json.jsonString(lsp_ctx.uri));

    var start_pos = ObjectMap.init(ctx.allocator);
    try start_pos.put("line", json.jsonInteger(@intCast(start_line)));
    try start_pos.put("character", json.jsonInteger(0));

    var end_pos = ObjectMap.init(ctx.allocator);
    try end_pos.put("line", json.jsonInteger(@intCast(end_line)));
    try end_pos.put("character", json.jsonInteger(0));

    var range = ObjectMap.init(ctx.allocator);
    try range.put("start", .{ .object = start_pos });
    try range.put("end", .{ .object = end_pos });

    var lsp_params = ObjectMap.init(ctx.allocator);
    try lsp_params.put("textDocument", .{ .object = td });
    try lsp_params.put("range", .{ .object = range });

    const request_id = try lsp_ctx.client.sendRequest("textDocument/inlayHint", .{ .object = lsp_params });

    return .{ .pending_lsp = .{ .lsp_request_id = request_id } };
}

fn handleFoldingRange(ctx: *HandlerContext, params: Value) !DispatchResult {
    const lsp_ctx = switch (try getLspContext(ctx, params)) {
        .ready => |c| c,
        .initializing => return .{ .initializing = {} },
        .not_available => return .{ .empty = {} },
    };

const lsp_params = try buildTextDocumentIdentifier(ctx.allocator, lsp_ctx.uri);
    const request_id = try lsp_ctx.client.sendRequest("textDocument/foldingRange", lsp_params);

    return .{ .pending_lsp = .{ .lsp_request_id = request_id } };
}

fn handleCallHierarchy(ctx: *HandlerContext, params: Value) !DispatchResult {
    const lsp_ctx = switch (try getLspContext(ctx, params)) {
        .ready => |c| c,
        .initializing => return .{ .initializing = {} },
        .not_available => return .{ .empty = {} },
    };

const obj = switch (params) {
        .object => |o| o,
        else => return .{ .empty = {} },
    };

    const line: u32 = @intCast(json.getInteger(obj, "line") orelse return .{ .empty = {} });
    const column: u32 = @intCast(json.getInteger(obj, "column") orelse return .{ .empty = {} });

    const lsp_params = try buildTextDocumentPosition(ctx.allocator, lsp_ctx.uri, line, column);
    const request_id = try lsp_ctx.client.sendRequest("textDocument/prepareCallHierarchy", lsp_params);

    return .{ .pending_lsp = .{ .lsp_request_id = request_id } };
}

fn handleExecuteCommand(ctx: *HandlerContext, params: Value) !DispatchResult {
    const lsp_ctx = switch (try getLspContext(ctx, params)) {
        .ready => |c| c,
        .initializing => return .{ .initializing = {} },
        .not_available => return .{ .empty = {} },
    };

const obj = switch (params) {
        .object => |o| o,
        else => return .{ .empty = {} },
    };

    const command = json.getString(obj, "lsp_command") orelse return .{ .empty = {} };

    var lsp_params = ObjectMap.init(ctx.allocator);
    try lsp_params.put("command", json.jsonString(command));
    if (obj.get("arguments")) |args| {
        try lsp_params.put("arguments", args);
    }

    const request_id = try lsp_ctx.client.sendRequest("workspace/executeCommand", .{ .object = lsp_params });

    return .{ .pending_lsp = .{ .lsp_request_id = request_id } };
}

// ============================================================================
// Document lifecycle notifications (fire-and-forget to LSP)
// ============================================================================

fn handleDidChange(ctx: *HandlerContext, params: Value) !DispatchResult {
    const lsp_ctx = switch (try getLspContext(ctx, params)) {
        .ready => |c| c,
        .initializing, .not_available => return .{ .empty = {} },
    };

const obj = switch (params) {
        .object => |o| o,
        else => return .{ .empty = {} },
    };

    // Build didChange params
    var td = ObjectMap.init(ctx.allocator);
    try td.put("uri", json.jsonString(lsp_ctx.uri));
    const version = json.getInteger(obj, "version") orelse 1;
    try td.put("version", json.jsonInteger(version));

    var lsp_params = ObjectMap.init(ctx.allocator);
    try lsp_params.put("textDocument", .{ .object = td });

    // Forward content changes if present
    if (obj.get("changes")) |changes| {
        try lsp_params.put("contentChanges", changes);
    } else if (json.getString(obj, "text")) |text| {
        var change = ObjectMap.init(ctx.allocator);
        try change.put("text", json.jsonString(text));
        var changes = std.json.Array.init(ctx.allocator);
        try changes.append(.{ .object = change });
        try lsp_params.put("contentChanges", .{ .array = changes });
    }

    lsp_ctx.client.sendNotification("textDocument/didChange", .{ .object = lsp_params }) catch |e| {
        log.err("Failed to send didChange: {any}", .{e});
    };

    return .{ .empty = {} };
}

fn handleDidSave(ctx: *HandlerContext, params: Value) !DispatchResult {
    const lsp_ctx = switch (try getLspContext(ctx, params)) {
        .ready => |c| c,
        .initializing, .not_available => return .{ .empty = {} },
    };

var td = ObjectMap.init(ctx.allocator);
    try td.put("uri", json.jsonString(lsp_ctx.uri));

    var lsp_params = ObjectMap.init(ctx.allocator);
    try lsp_params.put("textDocument", .{ .object = td });

    lsp_ctx.client.sendNotification("textDocument/didSave", .{ .object = lsp_params }) catch |e| {
        log.err("Failed to send didSave: {any}", .{e});
    };

    return .{ .empty = {} };
}

fn handleDidClose(ctx: *HandlerContext, params: Value) !DispatchResult {
    const lsp_ctx = switch (try getLspContext(ctx, params)) {
        .ready => |c| c,
        .initializing, .not_available => return .{ .empty = {} },
    };

const lsp_params = try buildTextDocumentIdentifier(ctx.allocator, lsp_ctx.uri);

    lsp_ctx.client.sendNotification("textDocument/didClose", lsp_params) catch |e| {
        log.err("Failed to send didClose: {any}", .{e});
    };

    return .{ .empty = {} };
}

fn handleWillSave(ctx: *HandlerContext, params: Value) !DispatchResult {
    const lsp_ctx = switch (try getLspContext(ctx, params)) {
        .ready => |c| c,
        .initializing, .not_available => return .{ .empty = {} },
    };

var td = ObjectMap.init(ctx.allocator);
    try td.put("uri", json.jsonString(lsp_ctx.uri));

    var lsp_params = ObjectMap.init(ctx.allocator);
    try lsp_params.put("textDocument", .{ .object = td });
    try lsp_params.put("reason", json.jsonInteger(1)); // Manual save

    lsp_ctx.client.sendNotification("textDocument/willSave", .{ .object = lsp_params }) catch |e| {
        log.err("Failed to send willSave: {any}", .{e});
    };

    return .{ .empty = {} };
}
