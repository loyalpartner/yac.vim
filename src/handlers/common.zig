const std = @import("std");
const json = @import("../json_utils.zig");
const vim = @import("../vim_protocol.zig");
const registry_mod = @import("../lsp_registry.zig");
const LspClient = @import("../lsp_client.zig").LspClient;
const log = @import("../log.zig");

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
    client_stream: std.net.Stream,
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

/// Get LSP context, optionally allowing initializing clients (for handleFileOpen).
pub fn getLspContextEx(ctx: *HandlerContext, params: Value, require_ready: bool) !LspContextResult {
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
pub fn buildTextDocumentPosition(allocator: Allocator, uri: []const u8, line: u32, column: u32) !Value {
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
pub fn buildTextDocumentIdentifier(allocator: Allocator, uri: []const u8) !Value {
    var td = ObjectMap.init(allocator);
    try td.put("uri", json.jsonString(uri));

    var params = ObjectMap.init(allocator);
    try params.put("textDocument", .{ .object = td });
    return .{ .object = params };
}

/// Send a Vim ex command.
pub fn vimEx(ctx: *HandlerContext, command: []const u8) !void {
    const encoded = try vim.encodeChannelCommand(ctx.allocator, .{ .ex = .{ .command = command } });
    defer ctx.allocator.free(encoded);
    try ctx.client_stream.writeAll(encoded);
    try ctx.client_stream.writeAll("\n");
}

/// Send a Vim call_async command.
pub fn vimCallAsync(ctx: *HandlerContext, func: []const u8, args: Value) !void {
    const encoded = try vim.encodeChannelCommand(ctx.allocator, .{ .call_async = .{
        .func = func,
        .args = args,
    } });
    defer ctx.allocator.free(encoded);
    try ctx.client_stream.writeAll(encoded);
    try ctx.client_stream.writeAll("\n");
}
