const std = @import("std");
const json = @import("../json_utils.zig");
const common = @import("common.zig");

const Value = json.Value;
const ObjectMap = json.ObjectMap;
const HandlerContext = common.HandlerContext;
const DispatchResult = common.DispatchResult;

pub fn handleHover(ctx: *HandlerContext, params: Value) !DispatchResult {
    return common.sendPositionRequest(ctx, params, "textDocument/hover");
}

pub fn handleCompletion(ctx: *HandlerContext, params: Value) !DispatchResult {
    const lsp_ctx = switch (try common.getLspContext(ctx, params)) {
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

    const lsp_params = try common.buildTextDocumentPosition(ctx.allocator, lsp_ctx.uri, line, column);
    const request_id = try lsp_ctx.client.sendRequest("textDocument/completion", lsp_params);

    return .{ .pending_lsp = .{ .lsp_request_id = request_id, .client_key = lsp_ctx.client_key } };
}

pub fn handleSignatureHelp(ctx: *HandlerContext, params: Value) !DispatchResult {
    return common.sendCapabilityCheckedPositionRequest(ctx, params, "textDocument/signatureHelp", "signatureHelpProvider", "signature help");
}

pub fn handleDocumentSymbols(ctx: *HandlerContext, params: Value) !DispatchResult {
    const lsp_ctx = switch (try common.getLspContext(ctx, params)) {
        .ready => |c| c,
        .initializing => return .{ .initializing = {} },
        .not_available => return .{ .empty = {} },
    };

    const lsp_params = try common.buildTextDocumentIdentifier(ctx.allocator, lsp_ctx.uri);
    const request_id = try lsp_ctx.client.sendRequest("textDocument/documentSymbol", lsp_params);

    return .{ .pending_lsp = .{ .lsp_request_id = request_id } };
}

pub fn handleInlayHints(ctx: *HandlerContext, params: Value) !DispatchResult {
    const lsp_ctx = switch (try common.getLspContext(ctx, params)) {
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

    const lsp_params = try json.buildObject(ctx.allocator, .{
        .{ "textDocument", try common.buildTextDocumentValue(ctx.allocator, lsp_ctx.uri) },
        .{ "range", try common.buildRange(ctx.allocator, start_line, 0, end_line, 0) },
    });

    const request_id = try lsp_ctx.client.sendRequest("textDocument/inlayHint", lsp_params);

    return .{ .pending_lsp = .{ .lsp_request_id = request_id } };
}

pub fn handleFoldingRange(ctx: *HandlerContext, params: Value) !DispatchResult {
    const lsp_ctx = switch (try common.getLspContext(ctx, params)) {
        .ready => |c| c,
        .initializing => return .{ .initializing = {} },
        .not_available => return .{ .empty = {} },
    };

    const lsp_params = try common.buildTextDocumentIdentifier(ctx.allocator, lsp_ctx.uri);
    const request_id = try lsp_ctx.client.sendRequest("textDocument/foldingRange", lsp_params);

    return .{ .pending_lsp = .{ .lsp_request_id = request_id } };
}

pub fn handleDocumentHighlight(ctx: *HandlerContext, params: Value) !DispatchResult {
    return common.sendPositionRequest(ctx, params, "textDocument/documentHighlight");
}

pub fn handleSemanticTokens(ctx: *HandlerContext, params: Value) !DispatchResult {
    const lsp_ctx = switch (try common.getLspContext(ctx, params)) {
        .ready => |c| c,
        .initializing => return .{ .initializing = {} },
        .not_available => return .{ .empty = {} },
    };

    if (common.checkUnsupported(ctx, lsp_ctx.client_key, "semanticTokensProvider", "semantic tokens")) return .{ .empty = {} };

    const lsp_params = try common.buildTextDocumentIdentifier(ctx.allocator, lsp_ctx.uri);
    const request_id = try lsp_ctx.client.sendRequest("textDocument/semanticTokens/full", lsp_params);

    return .{ .pending_lsp = .{ .lsp_request_id = request_id, .client_key = lsp_ctx.client_key } };
}
