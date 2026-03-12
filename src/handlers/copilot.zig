const std = @import("std");
const json = @import("../json_utils.zig");
const common = @import("common.zig");
const log = @import("../log.zig");
const registry_mod = @import("../lsp/registry.zig");

const Value = json.Value;
const ObjectMap = json.ObjectMap;
const HandlerContext = common.HandlerContext;
const DispatchResult = common.DispatchResult;
const LspRegistry = registry_mod.LspRegistry;

/// Track which URIs have been didOpen'd to the Copilot client.
/// Reset when copilot client is recreated (spawn_failed resets).
var copilot_opened_uris: std.StringHashMap(void) = std.StringHashMap(void).init(std.heap.page_allocator);

/// Ensure a file is open in the Copilot client before sending requests.
fn ensureCopilotDidOpen(ctx: *HandlerContext, client: *@import("../lsp/client.zig").LspClient, file: []const u8) void {
    const real_path = registry_mod.extractRealPath(file);
    const uri = registry_mod.filePathToUri(ctx.allocator, real_path) catch return;

    if (copilot_opened_uris.contains(uri)) return;

    const content = std.fs.cwd().readFileAlloc(ctx.allocator, real_path, 10 * 1024 * 1024) catch return;
    const lang = LspRegistry.detectLanguage(real_path) orelse "plaintext";

    var td_item = ObjectMap.init(ctx.allocator);
    td_item.put("uri", json.jsonString(uri)) catch return;
    td_item.put("languageId", json.jsonString(lang)) catch return;
    td_item.put("version", json.jsonInteger(1)) catch return;
    td_item.put("text", json.jsonString(content)) catch return;

    var params_obj = ObjectMap.init(ctx.allocator);
    params_obj.put("textDocument", .{ .object = td_item }) catch return;

    client.sendNotification("textDocument/didOpen", .{ .object = params_obj }) catch |e| {
        log.err("Failed to send didOpen to Copilot: {any}", .{e});
        return;
    };

    // Track it (need a stable copy of the URI string)
    const uri_owned = std.heap.page_allocator.dupe(u8, uri) catch return;
    copilot_opened_uris.put(uri_owned, {}) catch {
        std.heap.page_allocator.free(uri_owned);
    };
    log.info("Sent didOpen to Copilot for {s}", .{uri});
}

// ============================================================================
// Helper: get copilot client or return empty
// ============================================================================

fn getCopilotClient(ctx: *HandlerContext) ?*@import("../lsp/client.zig").LspClient {
    const client = ctx.registry.getOrCreateCopilotClient() orelse {
        const msg = "call yac#toast('[yac] copilot-language-server not found. Install: npm i -g @github/copilot-language-server')";
        common.vimEx(ctx, msg) catch {};
        return null;
    };
    return client;
}

fn copilotReady(ctx: *HandlerContext) bool {
    return !ctx.registry.isInitializing(LspRegistry.copilot_key);
}

// ============================================================================
// Authentication handlers
// ============================================================================

pub fn handleCopilotSignIn(ctx: *HandlerContext, _: Value) !DispatchResult {
    // Reset spawn failure flag on explicit sign-in to allow retry
    ctx.registry.resetCopilotSpawnFailed();
    const client = getCopilotClient(ctx) orelse return .{ .empty = {} };
    if (!copilotReady(ctx)) return .{ .initializing = {} };

    const request_id = try client.sendRequest("signIn", .{ .object = ObjectMap.init(ctx.allocator) });
    return .{ .pending_lsp = .{ .lsp_request_id = request_id, .client_key = LspRegistry.copilot_key } };
}

pub fn handleCopilotSignOut(ctx: *HandlerContext, _: Value) !DispatchResult {
    const client = getCopilotClient(ctx) orelse return .{ .empty = {} };
    if (!copilotReady(ctx)) return .{ .initializing = {} };

    const request_id = try client.sendRequest("signOut", .{ .object = ObjectMap.init(ctx.allocator) });
    return .{ .pending_lsp = .{ .lsp_request_id = request_id, .client_key = LspRegistry.copilot_key } };
}

pub fn handleCopilotCheckStatus(ctx: *HandlerContext, _: Value) !DispatchResult {
    const client = getCopilotClient(ctx) orelse return .{ .empty = {} };
    if (!copilotReady(ctx)) return .{ .initializing = {} };

    const request_id = try client.sendRequest("checkStatus", .{ .object = ObjectMap.init(ctx.allocator) });
    return .{ .pending_lsp = .{ .lsp_request_id = request_id, .client_key = LspRegistry.copilot_key } };
}

pub fn handleCopilotSignInConfirm(ctx: *HandlerContext, params: Value) !DispatchResult {
    const client = getCopilotClient(ctx) orelse return .{ .empty = {} };
    if (!copilotReady(ctx)) return .{ .initializing = {} };

    const obj = switch (params) {
        .object => |o| o,
        else => return .{ .empty = {} },
    };

    var confirm_params = ObjectMap.init(ctx.allocator);
    if (json.getString(obj, "userCode")) |code| {
        try confirm_params.put("userCode", json.jsonString(code));
    }

    const request_id = try client.sendRequest("signInConfirm", .{ .object = confirm_params });
    return .{ .pending_lsp = .{ .lsp_request_id = request_id, .client_key = LspRegistry.copilot_key } };
}

// ============================================================================
// Inline completion handler
// ============================================================================

pub fn handleCopilotComplete(ctx: *HandlerContext, params: Value) !DispatchResult {
    const client = getCopilotClient(ctx) orelse return .{ .empty = {} };
    if (!copilotReady(ctx)) return .{ .initializing = {} };

    const obj = switch (params) {
        .object => |o| o,
        else => return .{ .empty = {} },
    };

    const file = json.getString(obj, "file") orelse return .{ .empty = {} };
    const line: u32 = json.getU32(obj, "line") orelse return .{ .empty = {} };
    const column: u32 = json.getU32(obj, "column") orelse return .{ .empty = {} };

    // Ensure file is open in Copilot before requesting completions
    ensureCopilotDidOpen(ctx, client, file);

    const uri = try registry_mod.filePathToUri(ctx.allocator, registry_mod.extractRealPath(file));

    // Build textDocument/inlineCompletion params
    const tab_size = json.getInteger(obj, "tab_size") orelse 4;
    const insert_spaces = if (obj.get("insert_spaces")) |v| switch (v) {
        .bool => |b| b,
        else => true,
    } else true;

    const lsp_params = try json.buildObject(ctx.allocator, .{
        .{ "textDocument", try json.buildObject(ctx.allocator, .{
            .{ "uri", json.jsonString(uri) },
        }) },
        .{ "position", try json.buildObject(ctx.allocator, .{
            .{ "line", json.jsonInteger(@intCast(line)) },
            .{ "character", json.jsonInteger(@intCast(column)) },
        }) },
        .{ "context", try json.buildObject(ctx.allocator, .{
            .{ "triggerKind", json.jsonInteger(1) },
        }) },
        .{ "formattingOptions", try json.buildObject(ctx.allocator, .{
            .{ "tabSize", json.jsonInteger(tab_size) },
            .{ "insertSpaces", json.jsonBool(insert_spaces) },
        }) },
    });

    const request_id = try client.sendRequest("textDocument/inlineCompletion", lsp_params);
    return .{ .pending_lsp = .{ .lsp_request_id = request_id, .client_key = LspRegistry.copilot_key } };
}

// ============================================================================
// Lifecycle notifications
// ============================================================================

pub fn handleCopilotDidFocus(ctx: *HandlerContext, params: Value) !DispatchResult {
    const client = ctx.registry.copilot_client orelse return .{ .empty = {} };
    if (!copilotReady(ctx)) return .{ .empty = {} };

    const obj = switch (params) {
        .object => |o| o,
        else => return .{ .empty = {} },
    };

    const file = json.getString(obj, "file") orelse return .{ .empty = {} };
    const uri = try registry_mod.filePathToUri(ctx.allocator, registry_mod.extractRealPath(file));

    const notify_params = try json.buildObject(ctx.allocator, .{
        .{ "textDocument", try json.buildObject(ctx.allocator, .{
            .{ "uri", json.jsonString(uri) },
        }) },
    });

    client.sendNotification("textDocument/didFocus", notify_params) catch |e| {
        log.err("Failed to send didFocus to Copilot: {any}", .{e});
    };

    return .{ .empty = {} };
}

pub fn handleCopilotAccept(ctx: *HandlerContext, params: Value) !DispatchResult {
    const client = ctx.registry.copilot_client orelse return .{ .empty = {} };
    if (!copilotReady(ctx)) return .{ .empty = {} };

    const obj = switch (params) {
        .object => |o| o,
        else => return .{ .empty = {} },
    };

    // Build workspace/executeCommand for acceptance telemetry
    var args = std.json.Array.init(ctx.allocator);
    if (obj.get("uuid")) |uuid| {
        try args.append(uuid);
    }

    const cmd_params = try json.buildObject(ctx.allocator, .{
        .{ "command", json.jsonString("github.copilot.didAcceptCompletionItem") },
        .{ "arguments", .{ .array = args } },
    });

    client.sendNotification("workspace/executeCommand", cmd_params) catch |e| {
        log.err("Failed to send Copilot accept: {any}", .{e});
    };

    return .{ .empty = {} };
}

pub fn handleCopilotPartialAccept(ctx: *HandlerContext, params: Value) !DispatchResult {
    const client = ctx.registry.copilot_client orelse return .{ .empty = {} };
    if (!copilotReady(ctx)) return .{ .empty = {} };

    const obj = switch (params) {
        .object => |o| o,
        else => return .{ .empty = {} },
    };

    var notify_params = ObjectMap.init(ctx.allocator);
    if (json.getString(obj, "item_id")) |id| {
        try notify_params.put("itemId", json.jsonString(id));
    }
    if (json.getString(obj, "accepted_text")) |text| {
        try notify_params.put("acceptedLength", json.jsonInteger(@intCast(text.len)));
    }

    client.sendNotification("textDocument/didPartiallyAcceptCompletion", .{ .object = notify_params }) catch |e| {
        log.err("Failed to send Copilot partial accept: {any}", .{e});
    };

    return .{ .empty = {} };
}
