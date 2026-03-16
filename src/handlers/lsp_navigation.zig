const std = @import("std");
const json = @import("../json_utils.zig");
const common = @import("common.zig");
const lsp_transform = common.lsp_transform;

const HandlerContext = common.HandlerContext;

pub fn handleReferences(ctx: *HandlerContext, p: common.PositionParams) !?json.Value {
    const file = p.file orelse return null;
    const lsp_ctx = ctx.lsp(file) orelse return null;

    const line_i64 = p.line orelse return null;
    const col_i64 = p.column orelse return null;
    if (line_i64 < 0 or col_i64 < 0) return null;
    const line: u32 = @intCast(line_i64);
    const column: u32 = @intCast(col_i64);

    // Build references params (includes context.includeDeclaration)
    var lsp_params_obj = switch (try common.buildTextDocumentPosition(ctx.allocator, lsp_ctx.uri, line, column)) {
        .object => |o| o,
        else => unreachable,
    };

    try lsp_params_obj.put("context", try json.buildObject(ctx.allocator, .{
        .{ "includeDeclaration", json.jsonBool(true) },
    }));

    const lsp_params: json.Value = .{ .object = lsp_params_obj };
    try ctx.lspRequest(lsp_ctx.client, "textDocument/references", lsp_params, .{ .transform = lsp_transform.transformRefs });
    return null;
}
