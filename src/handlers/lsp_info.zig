const std = @import("std");
const json = @import("../json_utils.zig");
const common = @import("common.zig");
const lsp_types = @import("../lsp/types.zig");
const lsp_transform = common.lsp_transform;

const Value = json.Value;
const HandlerContext = common.HandlerContext;

// ============================================================================
// Vim → daemon param types
// ============================================================================

pub const CompletionParams = struct {
    file: ?[]const u8 = null,
    line: ?i64 = null,
    column: ?i64 = null,
};

pub const InlayHintParams = struct {
    file: ?[]const u8 = null,
    start_line: ?i64 = null,
    end_line: ?i64 = null,
};

pub fn handleCompletion(ctx: *HandlerContext, p: CompletionParams) !?Value {
    const file = p.file orelse return null;
    const lsp_ctx = ctx.lsp(file) orelse return null;

    const line_i64 = p.line orelse return null;
    if (line_i64 < 0) return null;
    const col_i64 = p.column orelse return null;
    if (col_i64 < 0) return null;

    try ctx.lspRequest(lsp_ctx.client, lsp_types.Completion{ .params = .{
        .textDocument = .{ .uri = lsp_ctx.uri },
        .position = .{ .line = line_i64, .character = col_i64 },
    } }, .{
        .client_key = lsp_ctx.client_key,
        .transform = lsp_transform.transformCompletion,
    });
    return null;
}

pub fn handleInlayHints(ctx: *HandlerContext, p: InlayHintParams) !?Value {
    const file = p.file orelse return null;
    const lsp_ctx = ctx.lsp(file) orelse return null;

    const start_line: i64 = if (p.start_line) |sl| if (sl >= 0) sl else 0 else 0;
    const end_line: i64 = if (p.end_line) |el| if (el >= 0) el else 100 else 100;

    try ctx.lspRequest(lsp_ctx.client, lsp_types.InlayHints{ .params = .{
        .textDocument = .{ .uri = lsp_ctx.uri },
        .range = .{
            .start = .{ .line = start_line, .character = 0 },
            .end = .{ .line = end_line, .character = 0 },
        },
    } }, .{ .transform = lsp_transform.transformInlayHint });
    return null;
}

pub fn handleSemanticTokens(ctx: *HandlerContext, p: common.FileParams) !?Value {
    const file = p.file orelse return null;
    const lsp_ctx = ctx.lsp(file) orelse return null;

    if (common.checkUnsupported(ctx, lsp_ctx.client_key, "semanticTokensProvider", "semantic tokens")) return null;

    try ctx.lspRequest(lsp_ctx.client, lsp_types.SemanticTokens{ .params = .{
        .textDocument = .{ .uri = lsp_ctx.uri },
    } }, .{
        .client_key = lsp_ctx.client_key,
        .transform = lsp_transform.transformSemTokens,
    });
    return null;
}

/// LSP document highlight — called from treesitter.zig as LSP fallback.
/// Uses getLspContextForFileEx directly (not ctx.lsp) to avoid auto-deferring.
pub fn handleDocumentHighlightLsp(ctx: *HandlerContext, p: common.PositionParams) !?Value {
    const file = p.file orelse return null;
    const result = try common.getLspContextForFileEx(ctx, file, false);
    const lsp_ctx = switch (result) {
        .ready => |c| c,
        .initializing, .not_available => return null,
    };

    const line_i64 = p.line orelse return null;
    const col_i64 = p.column orelse return null;
    if (line_i64 < 0 or col_i64 < 0) return null;

    try ctx.lspRequest(lsp_ctx.client, lsp_types.DocumentHighlightRequest{ .params = .{
        .textDocument = .{ .uri = lsp_ctx.uri },
        .position = .{ .line = line_i64, .character = col_i64 },
    } }, .{ .transform = lsp_transform.transformDocHighlight });
    return null;
}
