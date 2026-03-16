const std = @import("std");
const json = @import("../json_utils.zig");
const common = @import("common.zig");

const Value = json.Value;
const HandlerContext = common.HandlerContext;
const DispatchResult = common.DispatchResult;

// ============================================================================
// Vim → daemon param types
// ============================================================================

const CompletionParams = struct {
    file: ?[]const u8 = null,
    line: ?i64 = null,
    column: ?i64 = null,
};

const InlayHintParams = struct {
    file: ?[]const u8 = null,
    start_line: ?i64 = null,
    end_line: ?i64 = null,
};

pub fn handleHover(ctx: *HandlerContext, params: Value) !DispatchResult {
    return common.sendPositionRequest(ctx, params, "textDocument/hover");
}

pub fn handleCompletion(ctx: *HandlerContext, params: Value) !DispatchResult {
    const lsp_ctx = switch (try common.getLspContext(ctx, params)) {
        .ready => |c| c,
        .initializing => return .{ .initializing = {} },
        .not_available => return .{ .empty = {} },
    };

    const p = json.parseTyped(CompletionParams, ctx.allocator, params) orelse return .{ .empty = {} };

    const line_i64 = p.line orelse return .{ .empty = {} };
    if (line_i64 < 0) return .{ .empty = {} };
    const line: u32 = @intCast(line_i64);

    const col_i64 = p.column orelse return .{ .empty = {} };
    if (col_i64 < 0) return .{ .empty = {} };
    const column: u32 = @intCast(col_i64);

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

    const p = json.parseTyped(InlayHintParams, ctx.allocator, params) orelse return .{ .empty = {} };

    const start_line: u32 = if (p.start_line) |sl| if (sl >= 0) @as(u32, @intCast(sl)) else 0 else 0;
    const end_line: u32 = if (p.end_line) |el| if (el >= 0) @as(u32, @intCast(el)) else 100 else 100;

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
