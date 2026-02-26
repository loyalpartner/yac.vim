const std = @import("std");
const json = @import("../json_utils.zig");
const common = @import("common.zig");
const log = @import("../log.zig");
const ts_handlers = @import("treesitter.zig");

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

    const lsp_ctx = switch (try common.getLspContext(ctx, params)) {
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
