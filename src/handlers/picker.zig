const std = @import("std");
const json = @import("../json_utils.zig");
const common = @import("common.zig");
const lsp_types = @import("../lsp/types.zig");
const lsp_transform = common.lsp_transform;
const ts_mod = common.treesitter_mod;

const Value = json.Value;
const HandlerContext = common.HandlerContext;

// ============================================================================
// Vim → daemon param types
// ============================================================================

pub const PickerOpenParams = struct {
    cwd: ?[]const u8 = null,
    recent_files: Value = .null,
};

pub const PickerQueryParams = struct {
    query: ?[]const u8 = null,
    mode: ?[]const u8 = null,
    file: ?[]const u8 = null,
    text: ?[]const u8 = null,
};

// -- Named return types --

pub const PickerInitResult = struct {
    action: []const u8,
    cwd: []const u8,
    recent_files: Value = .null,
};

pub const PickerActionResult = struct {
    action: []const u8,
    query: []const u8 = "",
};

pub fn handlePickerOpen(ctx: *HandlerContext, p: PickerOpenParams) !?Value {
    const cwd = p.cwd orelse return null;

    var result = try json.buildObjectMap(ctx.allocator, .{
        .{ "action", json.jsonString("picker_init") },
        .{ "cwd", json.jsonString(cwd) },
    });
    if (p.recent_files != .null) {
        try result.put("recent_files", p.recent_files);
    }

    return .{ .object = result };
}

pub fn handlePickerQuery(ctx: *HandlerContext, p: PickerQueryParams) !?Value {
    const query = p.query orelse "";
    const mode = p.mode orelse "file";

    if (std.mem.eql(u8, mode, "workspace_symbol")) {
        const file = p.file orelse return null;
        const lsp_ctx = ctx.lsp(file) orelse return null;

        try ctx.lspRequest(lsp_ctx.client, lsp_types.WorkspaceSymbol{ .params = .{
            .query = query,
        } }, .{ .transform = lsp_transform.transformPickerSymbols });
        return null;
    } else if (std.mem.eql(u8, mode, "grep")) {
        return try json.structToValue(ctx.allocator, PickerActionResult{
            .action = "picker_grep_query",
            .query = query,
        });
    } else if (std.mem.eql(u8, mode, "document_symbol")) {
        const ts_state = ctx.ts orelse return null;
        const file = p.file orelse return null;
        const lang_state = ts_state.fromExtension(file) orelse return null;

        // Auto-parse if buffer not yet tracked (e.g. picker opened before highlights ran)
        if (ts_state.getTree(file) == null) {
            if (p.text) |text| {
                ts_state.parseBuffer(file, text) catch {};
            }
        }

        const tree = ts_state.getTree(file) orelse return null;
        const source = ts_state.getSource(file) orelse return null;
        const sym_query = lang_state.symbols orelse return null;

        return try ts_mod.symbols.extractPickerSymbols(
            ctx.allocator,
            sym_query,
            tree,
            source,
        );
    } else {
        return try json.structToValue(ctx.allocator, PickerActionResult{
            .action = "picker_file_query",
            .query = query,
        });
    }
}

pub fn handlePickerClose(ctx: *HandlerContext) !PickerActionResult {
    _ = ctx;
    return .{ .action = "picker_close" };
}
