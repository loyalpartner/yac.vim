const std = @import("std");
const json = @import("../json_utils.zig");
const common = @import("common.zig");

const Value = json.Value;
const ObjectMap = json.ObjectMap;
const HandlerContext = common.HandlerContext;
const DispatchResult = common.DispatchResult;

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

    const obj = switch (params) {
        .object => |o| o,
        else => return .{ .empty = {} },
    };

    const line: u32 = @intCast(json.getInteger(obj, "line") orelse return .{ .empty = {} });
    const column: u32 = @intCast(json.getInteger(obj, "column") orelse return .{ .empty = {} });

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
