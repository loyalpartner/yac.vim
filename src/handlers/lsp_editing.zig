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
    insert_spaces: bool = true,
};

pub const FormattingParams = struct {
    file: ?[]const u8 = null,
    tab_size: ?i64 = null,
    insert_spaces: bool = true,
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
    const new_name = p.new_name orelse return null;

    try ctx.lspRequest(lsp_ctx.client, try (lsp_types.Rename{ .params = .{
        .textDocument = .{ .uri = lsp_ctx.uri },
        .position = .{ .line = line_i64, .character = col_i64 },
        .newName = new_name,
    } }).wire(ctx.allocator), .{});
    return null;
}

pub fn handleCodeAction(ctx: *HandlerContext, p: common.PositionParams) !?Value {
    const file = p.file orelse return null;
    const lsp_ctx = ctx.lsp(file) orelse return null;

    const line_i64 = p.line orelse return null;
    const col_i64 = p.column orelse return null;
    if (line_i64 < 0 or col_i64 < 0) return null;

    try ctx.lspRequest(lsp_ctx.client, try (lsp_types.CodeAction{ .params = .{
        .textDocument = .{ .uri = lsp_ctx.uri },
        .range = .{
            .start = .{ .line = line_i64, .character = col_i64 },
            .end = .{ .line = line_i64, .character = col_i64 },
        },
        .context = .{ .diagnostics = .{ .array = std.json.Array.init(ctx.allocator) } },
    } }).wire(ctx.allocator), .{});
    return null;
}

pub fn handleFormatting(ctx: *HandlerContext, p: FormattingParams) !?Value {
    const file = p.file orelse return null;
    const lsp_ctx = ctx.lsp(file) orelse return null;

    if (common.checkUnsupported(ctx, lsp_ctx.client_key, "documentFormattingProvider", "formatting")) return null;

    try ctx.lspRequest(lsp_ctx.client, try (lsp_types.Formatting{ .params = .{
        .textDocument = .{ .uri = lsp_ctx.uri },
        .options = .{ .tabSize = p.tab_size orelse 4, .insertSpaces = p.insert_spaces },
    } }).wire(ctx.allocator), .{ .transform = lsp_transform.transformFmt });
    return null;
}

pub fn handleRangeFormatting(ctx: *HandlerContext, p: RangeFormattingParams) !?Value {
    const file = p.file orelse return null;
    const lsp_ctx = ctx.lsp(file) orelse return null;

    if (common.checkUnsupported(ctx, lsp_ctx.client_key, "documentRangeFormattingProvider", "range formatting")) return null;

    const start_line: i64 = if (p.start_line) |sl| if (sl >= 0) sl else 0 else 0;
    const start_col: i64 = if (p.start_column) |sc| if (sc >= 0) sc else 0 else 0;
    const end_line: i64 = if (p.end_line) |el| if (el >= 0) el else 0 else 0;
    const end_col: i64 = if (p.end_column) |ec| if (ec >= 0) ec else 0 else 0;

    try ctx.lspRequest(lsp_ctx.client, try (lsp_types.RangeFormatting{ .params = .{
        .textDocument = .{ .uri = lsp_ctx.uri },
        .range = .{
            .start = .{ .line = start_line, .character = start_col },
            .end = .{ .line = end_line, .character = end_col },
        },
        .options = .{ .tabSize = p.tab_size orelse 4, .insertSpaces = p.insert_spaces },
    } }).wire(ctx.allocator), .{ .transform = lsp_transform.transformFmt });
    return null;
}

pub fn handleExecuteCommand(ctx: *HandlerContext, p: ExecuteCommandParams) !?Value {
    const file = p.file orelse return null;
    const lsp_ctx = ctx.lsp(file) orelse return null;

    const command = p.lsp_command orelse return null;
    const args: ?Value = if (p.arguments != .null) p.arguments else null;

    try ctx.lspRequest(lsp_ctx.client, try (lsp_types.ExecuteCommand{ .params = .{
        .command = command,
        .arguments = args,
    } }).wire(ctx.allocator), .{});
    return null;
}
