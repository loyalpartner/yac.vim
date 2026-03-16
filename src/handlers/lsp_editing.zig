const std = @import("std");
const json = @import("../json_utils.zig");
const common = @import("common.zig");
const lsp_transform = common.lsp_transform;

const Value = json.Value;
const HandlerContext = common.HandlerContext;

// ============================================================================
// Vim → daemon param types
// ============================================================================

pub const RenameParams = struct {
    file: ?[]const u8 = null,
    line: ?i64 = null,
    column: ?i64 = null,
    new_name: ?[]const u8 = null,
};

pub const RangeFormattingParams = struct {
    file: ?[]const u8 = null,
    start_line: ?i64 = null,
    start_column: ?i64 = null,
    end_line: ?i64 = null,
    end_column: ?i64 = null,
    tab_size: ?i64 = null,
    insert_spaces: Value = .null,
};

pub const FormattingParams = struct {
    file: ?[]const u8 = null,
    tab_size: ?i64 = null,
    insert_spaces: Value = .null,
};

pub const ExecuteCommandParams = struct {
    file: ?[]const u8 = null,
    lsp_command: ?[]const u8 = null,
    arguments: Value = .null,
};

pub fn handleRename(ctx: *HandlerContext, p: RenameParams) !?Value {
    const file = p.file orelse return null;
    const lsp_ctx = ctx.lsp(file) orelse return null;

    const line_i64 = p.line orelse return null;
    const col_i64 = p.column orelse return null;
    if (line_i64 < 0 or col_i64 < 0) return null;
    const line: u32 = @intCast(line_i64);
    const column: u32 = @intCast(col_i64);
    const new_name = p.new_name orelse return null;

    var lsp_params_obj = switch (try common.buildTextDocumentPosition(ctx.allocator, lsp_ctx.uri, line, column)) {
        .object => |o| o,
        else => unreachable,
    };
    try lsp_params_obj.put("newName", json.jsonString(new_name));

    const lsp_params: Value = .{ .object = lsp_params_obj };
    try ctx.lspRequest(lsp_ctx.client, "textDocument/rename", lsp_params, .{});
    return null;
}

pub fn handleCodeAction(ctx: *HandlerContext, p: common.PositionParams) !?Value {
    const file = p.file orelse return null;
    const lsp_ctx = ctx.lsp(file) orelse return null;

    const line_i64 = p.line orelse return null;
    const col_i64 = p.column orelse return null;
    if (line_i64 < 0 or col_i64 < 0) return null;
    const line: u32 = @intCast(line_i64);
    const column: u32 = @intCast(col_i64);

    const lsp_params = try json.buildObject(ctx.allocator, .{
        .{ "textDocument", try common.buildTextDocumentValue(ctx.allocator, lsp_ctx.uri) },
        .{ "range", try common.buildRange(ctx.allocator, line, column, line, column) },
        .{ "context", try json.buildObject(ctx.allocator, .{
            .{ "diagnostics", .{ .array = std.json.Array.init(ctx.allocator) } },
        }) },
    });

    try ctx.lspRequest(lsp_ctx.client, "textDocument/codeAction", lsp_params, .{});
    return null;
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

pub fn handleFormatting(ctx: *HandlerContext, p: FormattingParams) !?Value {
    const file = p.file orelse return null;
    const lsp_ctx = ctx.lsp(file) orelse return null;

    if (common.checkUnsupported(ctx, lsp_ctx.client_key, "documentFormattingProvider", "formatting")) return null;

    const lsp_params = try json.buildObject(ctx.allocator, .{
        .{ "textDocument", try common.buildTextDocumentValue(ctx.allocator, lsp_ctx.uri) },
        .{ "options", try buildFormattingOptions(ctx.allocator, p.tab_size, p.insert_spaces) },
    });

    try ctx.lspRequest(lsp_ctx.client, "textDocument/formatting", lsp_params, .{ .transform = lsp_transform.transformFmt });
    return null;
}

pub fn handleRangeFormatting(ctx: *HandlerContext, p: RangeFormattingParams) !?Value {
    const file = p.file orelse return null;
    const lsp_ctx = ctx.lsp(file) orelse return null;

    if (common.checkUnsupported(ctx, lsp_ctx.client_key, "documentRangeFormattingProvider", "range formatting")) return null;

    const start_line: u32 = if (p.start_line) |sl| if (sl >= 0) @intCast(sl) else 0 else 0;
    const start_col: u32 = if (p.start_column) |sc| if (sc >= 0) @intCast(sc) else 0 else 0;
    const end_line: u32 = if (p.end_line) |el| if (el >= 0) @intCast(el) else 0 else 0;
    const end_col: u32 = if (p.end_column) |ec| if (ec >= 0) @intCast(ec) else 0 else 0;

    const lsp_params = try json.buildObject(ctx.allocator, .{
        .{ "textDocument", try common.buildTextDocumentValue(ctx.allocator, lsp_ctx.uri) },
        .{ "options", try buildFormattingOptions(ctx.allocator, p.tab_size, p.insert_spaces) },
        .{ "range", try common.buildRange(ctx.allocator, start_line, start_col, end_line, end_col) },
    });

    try ctx.lspRequest(lsp_ctx.client, "textDocument/rangeFormatting", lsp_params, .{ .transform = lsp_transform.transformFmt });
    return null;
}

pub fn handleExecuteCommand(ctx: *HandlerContext, p: ExecuteCommandParams) !?Value {
    const file = p.file orelse return null;
    const lsp_ctx = ctx.lsp(file) orelse return null;

    const command = p.lsp_command orelse return null;

    var lsp_params = try json.buildObjectMap(ctx.allocator, .{
        .{ "command", json.jsonString(command) },
    });
    if (p.arguments != .null) {
        try lsp_params.put("arguments", p.arguments);
    }

    const exec_value: Value = .{ .object = lsp_params };
    try ctx.lspRequest(lsp_ctx.client, "workspace/executeCommand", exec_value, .{});
    return null;
}
