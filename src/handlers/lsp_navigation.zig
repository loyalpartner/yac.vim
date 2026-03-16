const std = @import("std");
const json = @import("../json_utils.zig");
const common = @import("common.zig");
const lsp_types = @import("../lsp/types.zig");
const lsp_transform = common.lsp_transform;

const HandlerContext = common.HandlerContext;

pub fn handleReferences(ctx: *HandlerContext, p: common.PositionParams) !?json.Value {
    const file = p.file orelse return null;
    const lsp_ctx = ctx.lsp(file) orelse return null;

    const line_i64 = p.line orelse return null;
    const col_i64 = p.column orelse return null;
    if (line_i64 < 0 or col_i64 < 0) return null;

    try ctx.lspRequest(lsp_ctx.client, lsp_types.References{ .params = .{
        .textDocument = .{ .uri = lsp_ctx.uri },
        .position = .{ .line = line_i64, .character = col_i64 },
        .context = .{ .includeDeclaration = true },
    } }, .{ .transform = lsp_transform.transformRefs });
    return null;
}
