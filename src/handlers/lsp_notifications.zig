const std = @import("std");
const json = @import("../json_utils.zig");
const common = @import("common.zig");
const log = @import("../log.zig");
const ts_handlers = @import("treesitter.zig");
const registry_mod = @import("../lsp/registry.zig");

const Value = json.Value;
const ObjectMap = json.ObjectMap;
const HandlerContext = common.HandlerContext;
const DispatchResult = common.DispatchResult;

pub fn handleDiagnostics(_: *HandlerContext, _: Value) !DispatchResult {
    // Diagnostics are pushed by the server via notifications, not pulled.
    return .{ .empty = {} };
}

// ============================================================================
// Document lifecycle notifications (fire-and-forget to LSP)
// ============================================================================

pub fn handleDidChange(ctx: *HandlerContext, params: Value) !DispatchResult {
    // Tree-sitter parse: independent of LSP — always parse if supported
    ts_handlers.parseIfSupported(ctx, params);

    const obj = switch (params) {
        .object => |o| o,
        else => return .{ .empty = {} },
    };

    const lsp_ctx_result = try common.getLspContext(ctx, params);
    switch (lsp_ctx_result) {
        .ready => |lsp_ctx| {
            // Build didChange params
            const version = json.getInteger(obj, "version") orelse 1;
            var lsp_params = try json.buildObjectMap(ctx.allocator, .{
                .{ "textDocument", try json.buildObject(ctx.allocator, .{
                    .{ "uri", json.jsonString(lsp_ctx.uri) },
                    .{ "version", json.jsonInteger(version) },
                }) },
            });

            // Forward content changes if present
            if (obj.get("changes")) |changes| {
                try lsp_params.put("contentChanges", changes);
            } else if (json.getString(obj, "text")) |text| {
                var change = ObjectMap.init(ctx.allocator);
                try change.put("text", json.jsonString(text));
                var changes_arr = std.json.Array.init(ctx.allocator);
                try changes_arr.append(.{ .object = change });
                try lsp_params.put("contentChanges", .{ .array = changes_arr });
            }

            lsp_ctx.client.sendNotification("textDocument/didChange", .{ .object = lsp_params }) catch |e| {
                log.err("Failed to send didChange: {any}", .{e});
            };
        },
        .initializing, .not_available => {},
    }

    // Also forward to Copilot client
    forwardDidChangeToCopilot(ctx, obj);

    return .{ .empty = {} };
}

/// Forward didChange to the Copilot client (if active and initialized).
fn forwardDidChangeToCopilot(ctx: *HandlerContext, obj: ObjectMap) void {
    const copilot_client = ctx.registry.copilot_client orelse return;
    if (ctx.registry.isInitializing(registry_mod.LspRegistry.copilot_key)) return;

    const file = json.getString(obj, "file") orelse return;
    const real_path = registry_mod.extractRealPath(file);
    const uri = registry_mod.filePathToUri(ctx.allocator, real_path) catch return;
    const version = json.getInteger(obj, "version") orelse 1;

    var td = ObjectMap.init(ctx.allocator);
    td.put("uri", json.jsonString(uri)) catch return;
    td.put("version", json.jsonInteger(version)) catch return;

    var lsp_params = ObjectMap.init(ctx.allocator);
    lsp_params.put("textDocument", .{ .object = td }) catch return;

    if (obj.get("changes")) |changes| {
        lsp_params.put("contentChanges", changes) catch return;
    } else if (json.getString(obj, "text")) |text| {
        var change = ObjectMap.init(ctx.allocator);
        change.put("text", json.jsonString(text)) catch return;
        var changes_arr = std.json.Array.init(ctx.allocator);
        changes_arr.append(.{ .object = change }) catch return;
        lsp_params.put("contentChanges", .{ .array = changes_arr }) catch return;
    }

    copilot_client.sendNotification("textDocument/didChange", .{ .object = lsp_params }) catch |e| {
        log.err("Failed to send didChange to Copilot: {any}", .{e});
    };
}

pub fn handleDidSave(ctx: *HandlerContext, params: Value) !DispatchResult {
    const lsp_ctx = switch (try common.getLspContext(ctx, params)) {
        .ready => |c| c,
        .initializing, .not_available => return .{ .empty = {} },
    };

    const lsp_params = try common.buildTextDocumentIdentifier(ctx.allocator, lsp_ctx.uri);

    lsp_ctx.client.sendNotification("textDocument/didSave", lsp_params) catch |e| {
        log.err("Failed to send didSave: {any}", .{e});
    };

    return .{ .empty = {} };
}

pub fn handleDidClose(ctx: *HandlerContext, params: Value) !DispatchResult {
    // Tree-sitter cleanup: independent of LSP
    ts_handlers.removeIfSupported(ctx, params);

    const lsp_ctx = switch (try common.getLspContext(ctx, params)) {
        .ready => |c| c,
        .initializing, .not_available => return .{ .empty = {} },
    };

    const lsp_params = try common.buildTextDocumentIdentifier(ctx.allocator, lsp_ctx.uri);

    lsp_ctx.client.sendNotification("textDocument/didClose", lsp_params) catch |e| {
        log.err("Failed to send didClose: {any}", .{e});
    };

    return .{ .empty = {} };
}

pub fn handleWillSave(ctx: *HandlerContext, params: Value) !DispatchResult {
    const lsp_ctx = switch (try common.getLspContext(ctx, params)) {
        .ready => |c| c,
        .initializing, .not_available => return .{ .empty = {} },
    };

    var lsp_params = (try common.buildTextDocumentIdentifier(ctx.allocator, lsp_ctx.uri)).object;
    try lsp_params.put("reason", json.jsonInteger(1)); // Manual save

    lsp_ctx.client.sendNotification("textDocument/willSave", .{ .object = lsp_params }) catch |e| {
        log.err("Failed to send willSave: {any}", .{e});
    };

    return .{ .empty = {} };
}
