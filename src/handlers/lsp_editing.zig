const std = @import("std");
const json = @import("../json_utils.zig");
const common = @import("common.zig");

const Value = json.Value;
const ObjectMap = json.ObjectMap;
const HandlerContext = common.HandlerContext;
const DispatchResult = common.DispatchResult;

// ============================================================================
// Vim → daemon param types
// ============================================================================

const PositionParams = struct {
    file: ?[]const u8 = null,
    line: ?i64 = null,
    column: ?i64 = null,
};

const RenameParams = struct {
    file: ?[]const u8 = null,
    line: ?i64 = null,
    column: ?i64 = null,
    new_name: ?[]const u8 = null,
};

const RangeFormattingParams = struct {
    file: ?[]const u8 = null,
    start_line: ?i64 = null,
    start_column: ?i64 = null,
    end_line: ?i64 = null,
    end_column: ?i64 = null,
    tab_size: ?i64 = null,
    insert_spaces: Value = .null,
};

const FormattingParams = struct {
    file: ?[]const u8 = null,
    tab_size: ?i64 = null,
    insert_spaces: Value = .null,
};

const ExecuteCommandParams = struct {
    file: ?[]const u8 = null,
    lsp_command: ?[]const u8 = null,
    arguments: Value = .null,
};

pub fn handleRename(ctx: *HandlerContext, params: Value) !DispatchResult {
    const lsp_ctx = switch (try common.getLspContext(ctx, params)) {
        .ready => |c| c,
        .initializing => return .{ .initializing = {} },
        .not_available => return .{ .empty = {} },
    };

    const p = json.parseTyped(RenameParams, ctx.allocator, params) orelse return .{ .empty = {} };

    const line_i64 = p.line orelse return .{ .empty = {} };
    const col_i64 = p.column orelse return .{ .empty = {} };
    if (line_i64 < 0 or col_i64 < 0) return .{ .empty = {} };
    const line: u32 = @intCast(line_i64);
    const column: u32 = @intCast(col_i64);
    const new_name = p.new_name orelse return .{ .empty = {} };

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

    const p = json.parseTyped(PositionParams, ctx.allocator, params) orelse return .{ .empty = {} };
    const line_i64 = p.line orelse return .{ .empty = {} };
    const col_i64 = p.column orelse return .{ .empty = {} };
    if (line_i64 < 0 or col_i64 < 0) return .{ .empty = {} };
    const line: u32 = @intCast(line_i64);
    const column: u32 = @intCast(col_i64);

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

/// Build LSP FormattingOptions from parsed params.
fn buildFormattingOptions(allocator: std.mem.Allocator, tab_size: ?i64, insert_spaces: Value) !Value {
    const ts: i64 = tab_size orelse 4;
    const is: bool = switch (insert_spaces) {
        .bool => |b| b,
        else => true,
    };

    return json.buildObject(allocator, .{
        .{ "tabSize", json.jsonInteger(ts) },
        .{ "insertSpaces", json.jsonBool(is) },
    });
}

pub fn handleFormatting(ctx: *HandlerContext, params: Value) !DispatchResult {
    const lsp_ctx = switch (try common.getLspContext(ctx, params)) {
        .ready => |c| c,
        .initializing => return .{ .initializing = {} },
        .not_available => return .{ .empty = {} },
    };

    if (common.checkUnsupported(ctx, lsp_ctx.client_key, "documentFormattingProvider", "formatting")) return .{ .empty = {} };

    const p = json.parseTyped(FormattingParams, ctx.allocator, params) orelse return .{ .empty = {} };

    const lsp_params = try json.buildObject(ctx.allocator, .{
        .{ "textDocument", try common.buildTextDocumentValue(ctx.allocator, lsp_ctx.uri) },
        .{ "options", try buildFormattingOptions(ctx.allocator, p.tab_size, p.insert_spaces) },
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

    const p = json.parseTyped(RangeFormattingParams, ctx.allocator, params) orelse return .{ .empty = {} };

    const start_line: u32 = if (p.start_line) |sl| if (sl >= 0) @intCast(sl) else 0 else 0;
    const start_col: u32 = if (p.start_column) |sc| if (sc >= 0) @intCast(sc) else 0 else 0;
    const end_line: u32 = if (p.end_line) |el| if (el >= 0) @intCast(el) else 0 else 0;
    const end_col: u32 = if (p.end_column) |ec| if (ec >= 0) @intCast(ec) else 0 else 0;

    const lsp_params = try json.buildObject(ctx.allocator, .{
        .{ "textDocument", try common.buildTextDocumentValue(ctx.allocator, lsp_ctx.uri) },
        .{ "options", try buildFormattingOptions(ctx.allocator, p.tab_size, p.insert_spaces) },
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

    const p = json.parseTyped(ExecuteCommandParams, ctx.allocator, params) orelse return .{ .empty = {} };

    const command = p.lsp_command orelse return .{ .empty = {} };

    var lsp_params = try json.buildObjectMap(ctx.allocator, .{
        .{ "command", json.jsonString(command) },
    });
    if (p.arguments != .null) {
        try lsp_params.put("arguments", p.arguments);
    }

    const request_id = try lsp_ctx.client.sendRequest("workspace/executeCommand", .{ .object = lsp_params });

    return .{ .pending_lsp = .{ .lsp_request_id = request_id } };
}
