const std = @import("std");
const json = @import("../json_utils.zig");
const common = @import("common.zig");

const Value = json.Value;
const ObjectMap = json.ObjectMap;
const HandlerContext = common.HandlerContext;
const DispatchResult = common.DispatchResult;

pub fn handleRename(ctx: *HandlerContext, params: Value) !DispatchResult {
    const lsp_ctx = switch (try common.getLspContext(ctx, params)) {
        .ready => |c| c,
        .initializing => return .{ .initializing = {} },
        .not_available => return .{ .empty = {} },
    };

    const obj = switch (params) {
        .object => |o| o,
        else => return .{ .empty = {} },
    };

    const line: u32 = json.getU32(obj, "line") orelse return .{ .empty = {} };
    const column: u32 = json.getU32(obj, "column") orelse return .{ .empty = {} };
    const new_name = json.getString(obj, "new_name") orelse return .{ .empty = {} };

    var lsp_params_obj = switch (try common.buildTextDocumentPosition(ctx.allocator, lsp_ctx.uri, line, column)) {
        .object => |o| o,
        else => unreachable,
    };
    try lsp_params_obj.put("newName", json.jsonString(new_name));

    const request_id = try lsp_ctx.client.sendRequest("textDocument/rename", .{ .object = lsp_params_obj });

    return .{ .pending_lsp = .{ .lsp_request_id = request_id } };
}

pub fn handleCodeAction(ctx: *HandlerContext, params: Value) !DispatchResult {
    const lsp_ctx = switch (try common.getLspContext(ctx, params)) {
        .ready => |c| c,
        .initializing => return .{ .initializing = {} },
        .not_available => return .{ .empty = {} },
    };

    const obj = switch (params) {
        .object => |o| o,
        else => return .{ .empty = {} },
    };

    const line: u32 = json.getU32(obj, "line") orelse return .{ .empty = {} };
    const column: u32 = json.getU32(obj, "column") orelse return .{ .empty = {} };

    const lsp_params = try json.buildObject(ctx.allocator, .{
        .{ "textDocument", try common.buildTextDocumentValue(ctx.allocator, lsp_ctx.uri) },
        .{ "range", try common.buildRange(ctx.allocator, line, column, line, column) },
        .{ "context", try json.buildObject(ctx.allocator, .{
            .{ "diagnostics", .{ .array = std.json.Array.init(ctx.allocator) } },
        }) },
    });

    const request_id = try lsp_ctx.client.sendRequest("textDocument/codeAction", lsp_params);

    return .{ .pending_lsp = .{ .lsp_request_id = request_id } };
}

/// Build LSP FormattingOptions from Vim params (tab_size, insert_spaces).
fn buildFormattingOptions(allocator: std.mem.Allocator, obj: ObjectMap) !Value {
    const tab_size: i64 = json.getInteger(obj, "tab_size") orelse 4;
    const insert_spaces = if (obj.get("insert_spaces")) |v| switch (v) {
        .bool => |b| b,
        else => true,
    } else true;

    return json.buildObject(allocator, .{
        .{ "tabSize", json.jsonInteger(tab_size) },
        .{ "insertSpaces", json.jsonBool(insert_spaces) },
    });
}

pub fn handleFormatting(ctx: *HandlerContext, params: Value) !DispatchResult {
    const lsp_ctx = switch (try common.getLspContext(ctx, params)) {
        .ready => |c| c,
        .initializing => return .{ .initializing = {} },
        .not_available => return .{ .empty = {} },
    };

    if (common.checkUnsupported(ctx, lsp_ctx.client_key, "documentFormattingProvider", "formatting")) return .{ .empty = {} };

    const obj = switch (params) {
        .object => |o| o,
        else => return .{ .empty = {} },
    };

    const lsp_params = try json.buildObject(ctx.allocator, .{
        .{ "textDocument", try common.buildTextDocumentValue(ctx.allocator, lsp_ctx.uri) },
        .{ "options", try buildFormattingOptions(ctx.allocator, obj) },
    });

    const request_id = try lsp_ctx.client.sendRequest("textDocument/formatting", lsp_params);

    return .{ .pending_lsp = .{ .lsp_request_id = request_id } };
}

pub fn handleRangeFormatting(ctx: *HandlerContext, params: Value) !DispatchResult {
    const lsp_ctx = switch (try common.getLspContext(ctx, params)) {
        .ready => |c| c,
        .initializing => return .{ .initializing = {} },
        .not_available => return .{ .empty = {} },
    };

    if (common.checkUnsupported(ctx, lsp_ctx.client_key, "documentRangeFormattingProvider", "range formatting")) return .{ .empty = {} };

    const obj = switch (params) {
        .object => |o| o,
        else => return .{ .empty = {} },
    };

    const start_line: u32 = json.getU32(obj, "start_line") orelse 0;
    const start_col: u32 = json.getU32(obj, "start_column") orelse 0;
    const end_line: u32 = json.getU32(obj, "end_line") orelse 0;
    const end_col: u32 = json.getU32(obj, "end_column") orelse 0;

    const lsp_params = try json.buildObject(ctx.allocator, .{
        .{ "textDocument", try common.buildTextDocumentValue(ctx.allocator, lsp_ctx.uri) },
        .{ "options", try buildFormattingOptions(ctx.allocator, obj) },
        .{ "range", try common.buildRange(ctx.allocator, start_line, start_col, end_line, end_col) },
    });

    const request_id = try lsp_ctx.client.sendRequest("textDocument/rangeFormatting", lsp_params);

    return .{ .pending_lsp = .{ .lsp_request_id = request_id } };
}

pub fn handleExecuteCommand(ctx: *HandlerContext, params: Value) !DispatchResult {
    const lsp_ctx = switch (try common.getLspContext(ctx, params)) {
        .ready => |c| c,
        .initializing => return .{ .initializing = {} },
        .not_available => return .{ .empty = {} },
    };

    const obj = switch (params) {
        .object => |o| o,
        else => return .{ .empty = {} },
    };

    const command = json.getString(obj, "lsp_command") orelse return .{ .empty = {} };

    var lsp_params = try json.buildObjectMap(ctx.allocator, .{
        .{ "command", json.jsonString(command) },
    });
    if (obj.get("arguments")) |args| {
        try lsp_params.put("arguments", args);
    }

    const request_id = try lsp_ctx.client.sendRequest("workspace/executeCommand", .{ .object = lsp_params });

    return .{ .pending_lsp = .{ .lsp_request_id = request_id } };
}
