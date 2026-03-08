const std = @import("std");
const json = @import("../json_utils.zig");
const common = @import("common.zig");
const log = @import("../log.zig");
const ts_handlers = @import("treesitter.zig");
const registry_mod = @import("../lsp/registry.zig");

const lsp_mod = @import("../lsp/lsp.zig");

const Value = json.Value;
const ObjectMap = json.ObjectMap;
const HandlerContext = common.HandlerContext;
const DispatchResult = common.DispatchResult;

/// Synchronous handler: query daemon-internal LSP readiness without any LSP round-trip.
pub fn handleLspStatus(ctx: *HandlerContext, params: Value) !DispatchResult {
    const obj = switch (params) {
        .object => |o| o,
        else => return .{ .empty = {} },
    };
    const file = json.getString(obj, "file") orelse return .{ .empty = {} };
    const real_path = registry_mod.extractRealPath(file);
    const language = registry_mod.LspRegistry.detectLanguage(real_path) orelse {
        return .{ .data = try json.buildObject(ctx.allocator, .{
            .{ "ready", .{ .bool = false } },
            .{ "reason", json.jsonString("unsupported_language") },
        }) };
    };

    const client_result = ctx.registry.findClient(language, real_path);

    if (client_result) |cr| {
        const initializing = ctx.registry.isInitializing(cr.client_key);
        const state = cr.client.state;
        const lang_from_key = lsp_mod.extractLanguageFromKey(cr.client_key);
        const indexing = ctx.lsp.isLanguageIndexing(lang_from_key);
        const ready = state == .initialized and !initializing and !indexing;

        return .{ .data = try json.buildObject(ctx.allocator, .{
            .{ "ready", json.jsonBool(ready) },
            .{ "state", json.jsonString(@tagName(state)) },
            .{ "initializing", json.jsonBool(initializing) },
            .{ "indexing", json.jsonBool(indexing) },
        }) };
    } else {
        return .{ .data = try json.buildObject(ctx.allocator, .{
            .{ "ready", .{ .bool = false } },
            .{ "reason", json.jsonString("no_client") },
        }) };
    }
}

pub fn handleFileOpen(ctx: *HandlerContext, params: Value) !DispatchResult {
    ts_handlers.parseIfSupported(ctx, params);

    const obj = switch (params) {
        .object => |o| o,
        else => return .{ .empty = {} },
    };

    const lsp_ctx_result = try common.getLspContextEx(ctx, params, false);

    var workspace_uri: ?[]const u8 = null;

    // Send didOpen to language-specific LSP if available
    switch (lsp_ctx_result) {
        .ready => |lsp_ctx| {
            workspace_uri = lsp_mod.extractWorkspaceFromKey(lsp_ctx.client_key);

            const content_to_use = json.getString(obj, "text") orelse
                (std.fs.cwd().readFileAlloc(ctx.allocator, lsp_ctx.real_path, 10 * 1024 * 1024) catch |e| {
                    log.err("Failed to read file {s}: {any}", .{ lsp_ctx.real_path, e });
                    return .{ .empty = {} };
                });

            if (ctx.registry.isInitializing(lsp_ctx.client_key)) {
                ctx.registry.queuePendingOpen(lsp_ctx.client_key, lsp_ctx.uri, lsp_ctx.language, content_to_use) catch |e| {
                    log.err("Failed to queue pending open: {any}", .{e});
                };
            } else {
                var td_item = ObjectMap.init(ctx.allocator);
                try td_item.put("uri", json.jsonString(lsp_ctx.uri));
                try td_item.put("languageId", json.jsonString(lsp_ctx.language));
                try td_item.put("version", json.jsonInteger(1));
                try td_item.put("text", json.jsonString(content_to_use));

                var did_open_params = ObjectMap.init(ctx.allocator);
                try did_open_params.put("textDocument", .{ .object = td_item });

                lsp_ctx.client.sendNotification("textDocument/didOpen", .{ .object = did_open_params }) catch |e| {
                    log.err("Failed to send didOpen: {any}", .{e});
                };
            }
        },
        .initializing, .not_available => {},
    }

    // Also send didOpen to Copilot client if it exists and is ready
    forwardDidOpenToCopilot(ctx, obj);

    const result_data = try json.buildObject(ctx.allocator, .{
        .{ "action", json.jsonString("none") },
    });

    if (workspace_uri) |ws| {
        return .{ .data_with_subscribe = .{ .data = result_data, .workspace_uri = ws } };
    }
    return .{ .data = result_data };
}

/// Forward didOpen to the Copilot client (if active and initialized).
fn forwardDidOpenToCopilot(ctx: *HandlerContext, obj: ObjectMap) void {
    if (ctx.registry.copilot_client == null) return;

    const file = json.getString(obj, "file") orelse return;
    const real_path = registry_mod.extractRealPath(file);
    const uri = registry_mod.filePathToUri(ctx.allocator, real_path) catch return;
    const content = json.getString(obj, "text") orelse
        (std.fs.cwd().readFileAlloc(ctx.allocator, real_path, 10 * 1024 * 1024) catch return);
    const lang = registry_mod.LspRegistry.detectLanguage(real_path) orelse "plaintext";

    // If copilot is still initializing, queue the didOpen for replay
    if (ctx.registry.isInitializing(registry_mod.LspRegistry.copilot_key)) {
        ctx.registry.queuePendingOpen(registry_mod.LspRegistry.copilot_key, uri, lang, content) catch |e| {
            log.err("Failed to queue pending didOpen for Copilot: {any}", .{e});
        };
        return;
    }

    const copilot_client = ctx.registry.copilot_client orelse return;

    var td_item = ObjectMap.init(ctx.allocator);
    td_item.put("uri", json.jsonString(uri)) catch return;
    td_item.put("languageId", json.jsonString(lang)) catch return;
    td_item.put("version", json.jsonInteger(1)) catch return;
    td_item.put("text", json.jsonString(content)) catch return;

    var params_obj = ObjectMap.init(ctx.allocator);
    params_obj.put("textDocument", .{ .object = td_item }) catch return;

    copilot_client.sendNotification("textDocument/didOpen", .{ .object = params_obj }) catch |e| {
        log.err("Failed to send didOpen to Copilot: {any}", .{e});
        return;
    };
    log.info("Forwarded didOpen to Copilot for {s}", .{uri});
}
