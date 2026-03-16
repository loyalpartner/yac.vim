const std = @import("std");
const json = @import("../json_utils.zig");
const vim = @import("../vim_protocol.zig");
const registry_mod = @import("../lsp/registry.zig");
const LspClient = @import("../lsp/client.zig").LspClient;
const log = @import("../log.zig");
pub const treesitter_mod = @import("../treesitter/treesitter.zig");
const queue_mod = @import("../queue.zig");
const lsp_mod = @import("../lsp/lsp.zig");
const clients_mod = @import("../clients.zig");

const dap_session_mod = @import("../dap/session.zig");

const Allocator = std.mem.Allocator;
const Value = json.Value;
const ObjectMap = json.ObjectMap;
const LspRegistry = registry_mod.LspRegistry;
const ClientId = clients_mod.ClientId;

// ============================================================================
// Handler Context - what every handler receives
// ============================================================================

pub const HandlerContext = struct {
    /// Arena allocator for request-scope temporary allocations.
    allocator: Allocator,
    /// GPA allocator for allocations that must outlive the request (e.g. OutMessage bytes).
    gpa_allocator: Allocator,
    registry: *LspRegistry,
    lsp: *lsp_mod.Lsp,
    client_stream: std.net.Stream,
    client_id: ClientId,
    ts: ?*treesitter_mod.TreeSitter = null,
    /// Active DAP debug session (single session at a time).
    dap_session: *?*dap_session_mod.DapSession = undefined,
    /// Outgoing message queue — push OutMessages here instead of writing directly.
    out_queue: *queue_mod.OutQueue,
    /// Set to true to request daemon shutdown.
    shutdown_flag: *bool = undefined,
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
        client_key: ?[]const u8 = null,
    },
    /// LSP client is still initializing; caller should defer and retry.
    initializing: void,
    /// Handler produced a response AND requests workspace subscription.
    data_with_subscribe: struct {
        data: Value,
        workspace_uri: []const u8,
    },
};

// ============================================================================
// Helper: extract file/line/column, detect language, get LSP client
// ============================================================================

pub const LspContext = struct {
    language: []const u8,
    client_key: []const u8,
    uri: []const u8,
    client: *LspClient,
    ssh_host: ?[]const u8,
    real_path: []const u8,
};

/// Result of trying to get LSP context.
pub const LspContextResult = union(enum) {
    /// Context is ready.
    ready: LspContext,
    /// Client is still initializing (caller should defer).
    initializing: void,
    /// No context available (unsupported language, bad params, etc.).
    not_available: void,
};

/// Get LSP context for a request.
pub fn getLspContext(ctx: *HandlerContext, params: Value) !LspContextResult {
    return getLspContextEx(ctx, params, true);
}

const FileParam = struct {
    file: ?[]const u8 = null,
};

const PositionParam = struct {
    file: ?[]const u8 = null,
    line: ?i64 = null,
    column: ?i64 = null,
};

/// Get LSP context, optionally allowing initializing clients (for handleFileOpen).
pub fn getLspContextEx(ctx: *HandlerContext, params: Value, require_ready: bool) !LspContextResult {
    const p = json.parseTyped(FileParam, ctx.allocator, params) orelse return .{ .not_available = {} };

    const file = p.file orelse return .{ .not_available = {} };
    const real_path = registry_mod.extractRealPath(file);
    const ssh_host = registry_mod.extractSshHost(file);

    const language = LspRegistry.detectLanguage(real_path) orelse {
        log.debug("No language detected for {s}", .{real_path});
        return .{ .not_available = {} };
    };

    // Skip repeated spawn attempts for servers known to be unavailable
    if (ctx.registry.hasSpawnFailed(language)) {
        return .{ .not_available = {} };
    }

    const result = ctx.registry.getOrCreateClient(language, real_path) catch |e| {
        log.err("LSP server not available for {s}: {any}", .{ language, e });
        ctx.registry.markSpawnFailed(language);
        const config = LspRegistry.getConfig(language);
        const cmd = if (config) |c| c.command else language;
        // Safety: reject values containing single quotes to prevent Vim command injection
        if (std.mem.indexOfScalar(u8, language, '\'') != null or
            std.mem.indexOfScalar(u8, cmd, '\'') != null)
        {
            return .{ .not_available = {} };
        }
        const msg = std.fmt.allocPrint(ctx.allocator, "call yac_install#on_spawn_failed('{s}', '{s}')", .{ language, cmd }) catch {
            return .{ .not_available = {} };
        };
        vimEx(ctx, msg) catch {};
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
pub fn buildTextDocumentPosition(allocator: Allocator, uri: []const u8, line: u32, column: u32) !Value {
    return json.buildObject(allocator, .{
        .{ "textDocument", try buildTextDocumentValue(allocator, uri) },
        .{ "position", try json.buildObject(allocator, .{
            .{ "line", json.jsonInteger(@intCast(line)) },
            .{ "character", json.jsonInteger(@intCast(column)) },
        }) },
    });
}

/// Build an LSP Range object: {start: {line, character}, end: {line, character}}.
pub fn buildRange(allocator: Allocator, start_line: u32, start_col: u32, end_line: u32, end_col: u32) !Value {
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

/// Build a textDocument JSON value ({uri: ...}) for embedding in LSP params.
pub fn buildTextDocumentValue(allocator: Allocator, uri: []const u8) !Value {
    return json.buildObject(allocator, .{
        .{ "uri", json.jsonString(uri) },
    });
}

/// Build textDocument identifier params for LSP ({textDocument: {uri: ...}}).
pub fn buildTextDocumentIdentifier(allocator: Allocator, uri: []const u8) !Value {
    return json.buildObject(allocator, .{
        .{ "textDocument", try buildTextDocumentValue(allocator, uri) },
    });
}

/// Send a Vim ex command via the out_queue (non-blocking; drops if queue full).
pub fn vimEx(ctx: *HandlerContext, command: []const u8) !void {
    const encoded = try vim.encodeChannelCommand(ctx.allocator, .{ .ex = .{ .command = command } });
    defer ctx.allocator.free(encoded);
    // GPA-allocate bytes including newline so they survive past the arena.
    const msg = try ctx.gpa_allocator.alloc(u8, encoded.len + 1);
    @memcpy(msg[0..encoded.len], encoded);
    msg[encoded.len] = '\n';
    if (!ctx.out_queue.push(.{ .stream = ctx.client_stream, .bytes = msg })) {
        ctx.gpa_allocator.free(msg);
        log.warn("vimEx: out queue full, dropping command", .{});
    }
}

/// Check if the server supports a capability; if not, send a toast and return true (= unsupported).
pub fn checkUnsupported(ctx: *HandlerContext, client_key: []const u8, capability: []const u8, feature_name: []const u8) bool {
    if (!ctx.registry.serverSupports(client_key, capability)) {
        const msg = std.fmt.allocPrint(ctx.allocator, "call yac#toast('[yac] Server does not support {s}')", .{feature_name}) catch return true;
        vimEx(ctx, msg) catch {};
        return true;
    }
    return false;
}

// ============================================================================
// Shared LSP request helpers (used by lsp_navigation, lsp_info, lsp_editing)
// ============================================================================

pub fn sendPositionRequest(ctx: *HandlerContext, params: Value, lsp_method: []const u8) !DispatchResult {
    const lsp_ctx = switch (try getLspContext(ctx, params)) {
        .ready => |c| c,
        .initializing => return .{ .initializing = {} },
        .not_available => return .{ .empty = {} },
    };

    const p = json.parseTyped(PositionParam, ctx.allocator, params) orelse return .{ .empty = {} };
    const line_i64 = p.line orelse return .{ .empty = {} };
    const col_i64 = p.column orelse return .{ .empty = {} };
    if (line_i64 < 0 or col_i64 < 0) return .{ .empty = {} };
    const line: u32 = @intCast(line_i64);
    const column: u32 = @intCast(col_i64);

    const lsp_params = try buildTextDocumentPosition(ctx.allocator, lsp_ctx.uri, line, column);
    const request_id = try lsp_ctx.client.sendRequest(lsp_method, lsp_params);

    return .{ .pending_lsp = .{ .lsp_request_id = request_id } };
}

/// Like sendPositionRequest, but first checks that the server advertises the given capability.
pub fn sendCapabilityCheckedPositionRequest(ctx: *HandlerContext, params: Value, lsp_method: []const u8, capability: []const u8, feature_name: []const u8) !DispatchResult {
    const lsp_ctx = switch (try getLspContext(ctx, params)) {
        .ready => |c| c,
        .initializing => return .{ .initializing = {} },
        .not_available => return .{ .empty = {} },
    };

    if (checkUnsupported(ctx, lsp_ctx.client_key, capability, feature_name)) return .{ .empty = {} };

    const p = json.parseTyped(PositionParam, ctx.allocator, params) orelse return .{ .empty = {} };
    const line_i64 = p.line orelse return .{ .empty = {} };
    const col_i64 = p.column orelse return .{ .empty = {} };
    if (line_i64 < 0 or col_i64 < 0) return .{ .empty = {} };
    const line: u32 = @intCast(line_i64);
    const column: u32 = @intCast(col_i64);

    const lsp_params = try buildTextDocumentPosition(ctx.allocator, lsp_ctx.uri, line, column);
    const request_id = try lsp_ctx.client.sendRequest(lsp_method, lsp_params);

    return .{ .pending_lsp = .{ .lsp_request_id = request_id } };
}

/// Send a Vim call_async command via the out_queue (non-blocking; drops if queue full).
pub fn vimCallAsync(ctx: *HandlerContext, func: []const u8, args: Value) !void {
    const encoded = try vim.encodeChannelCommand(ctx.allocator, .{ .call_async = .{
        .func = func,
        .args = args,
    } });
    defer ctx.allocator.free(encoded);
    const msg = try ctx.gpa_allocator.alloc(u8, encoded.len + 1);
    @memcpy(msg[0..encoded.len], encoded);
    msg[encoded.len] = '\n';
    if (!ctx.out_queue.push(.{ .stream = ctx.client_stream, .bytes = msg })) {
        ctx.gpa_allocator.free(msg);
        log.warn("vimCallAsync: out queue full, dropping call", .{});
    }
}
