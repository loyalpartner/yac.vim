const std = @import("std");
const json = @import("../json_utils.zig");
const common = @import("common.zig");
const lsp_types = @import("../lsp/types.zig");
const lsp_transform = common.lsp_transform;
const ts_mod = common.treesitter_mod;
const picker_mod = common.picker_mod;

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

pub fn handlePickerOpen(ctx: *HandlerContext, p: PickerOpenParams) !?Value {
    const cwd = p.cwd orelse return null;
    const picker = ctx.picker;

    if (!picker.start(cwd)) return null;

    // Pre-seed MRU from Vim
    if (p.recent_files == .array) {
        const rf_arr = p.recent_files.array.items;
        var names: std.ArrayList([]const u8) = .{};
        defer names.deinit(ctx.allocator);
        for (rf_arr) |v| {
            if (v == .string) names.append(ctx.allocator, v.string) catch {};
        }
        picker.setRecentFiles(names.items);
    }

    // Request buffer list from Vim — result handled in handleVimExprResponse.
    // For now, return recent files immediately; buffer list will be merged on response.
    ctx._picker_query_buffers = true;
    return null;
}

pub fn handlePickerQuery(ctx: *HandlerContext, p: PickerQueryParams) !?Value {
    const query = p.query orelse "";
    const mode = p.mode orelse "file";
    const picker = ctx.picker;

    if (std.mem.eql(u8, mode, "workspace_symbol")) {
        const file = p.file orelse return null;
        const lsp_ctx = ctx.lsp(file) orelse return null;

        try ctx.lspRequest(lsp_ctx.client, try (lsp_types.WorkspaceSymbol{ .params = .{
            .query = query,
        } }).wire(ctx.allocator), .{ .transform = lsp_transform.transformPickerSymbols });
        return null;
    } else if (std.mem.eql(u8, mode, "grep")) {
        if (query.len == 0) return null;
        const cwd = picker.cwd orelse return null;
        return picker_mod.runGrep(ctx.allocator, query, cwd) catch return null;
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
        // File mode — query the picker's file index directly
        if (!picker.hasIndex()) return null;
        picker.pollScan();
        if (query.len == 0) {
            return picker_mod.buildPickerResults(ctx.allocator, picker.recentFiles(), "file");
        }
        const file_list = picker.files();
        const recent = picker.recentFiles();
        const indices = picker_mod.filterAndSort(ctx.allocator, file_list, query, recent) catch return null;
        var items: std.ArrayList([]const u8) = .{};
        for (indices) |idx| {
            items.append(ctx.allocator, file_list[idx]) catch {};
        }
        return picker_mod.buildPickerResults(ctx.allocator, items.items, "file");
    }
}

pub fn handlePickerClose(ctx: *HandlerContext) !?Value {
    ctx.picker.close();
    return null;
}
