const std = @import("std");
const json = @import("../json_utils.zig");
const common = @import("common.zig");

const Value = json.Value;
const ObjectMap = json.ObjectMap;
const HandlerContext = common.HandlerContext;
const DispatchResult = common.DispatchResult;

const ReferencesParams = struct {
    line: ?i64 = null,
    column: ?i64 = null,
};

pub fn handleGotoDefinition(ctx: *HandlerContext, params: Value) !DispatchResult {
    return common.sendPositionRequest(ctx, params, "textDocument/definition");
}

pub fn handleGotoDeclaration(ctx: *HandlerContext, params: Value) !DispatchResult {
    return common.sendPositionRequest(ctx, params, "textDocument/declaration");
}

pub fn handleGotoTypeDefinition(ctx: *HandlerContext, params: Value) !DispatchResult {
    return common.sendPositionRequest(ctx, params, "textDocument/typeDefinition");
}

pub fn handleGotoImplementation(ctx: *HandlerContext, params: Value) !DispatchResult {
    return common.sendPositionRequest(ctx, params, "textDocument/implementation");
}

pub fn handleReferences(ctx: *HandlerContext, params: Value) !DispatchResult {
    const lsp_ctx = switch (try common.getLspContext(ctx, params)) {
        .ready => |c| c,
        .initializing => return .{ .initializing = {} },
        .not_available => return .{ .empty = {} },
    };

    const p = json.parseTyped(ReferencesParams, ctx.allocator, params) orelse return .{ .empty = {} };
    const line_i64 = p.line orelse return .{ .empty = {} };
    const col_i64 = p.column orelse return .{ .empty = {} };
    if (line_i64 < 0 or col_i64 < 0) return .{ .empty = {} };
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

    const request_id = try lsp_ctx.client.sendRequest("textDocument/references", .{ .object = lsp_params_obj });

    return .{ .pending_lsp = .{ .lsp_request_id = request_id } };
}

pub fn handleCallHierarchy(ctx: *HandlerContext, params: Value) !DispatchResult {
    return common.sendPositionRequest(ctx, params, "textDocument/prepareCallHierarchy");
}

pub fn handleTypeHierarchy(ctx: *HandlerContext, params: Value) !DispatchResult {
    return common.sendCapabilityCheckedPositionRequest(ctx, params, "textDocument/prepareTypeHierarchy", "typeHierarchyProvider", "type hierarchy");
}
