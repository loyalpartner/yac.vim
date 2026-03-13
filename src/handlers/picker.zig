const std = @import("std");
const json = @import("../json_utils.zig");
const common = @import("common.zig");
const ts_mod = common.treesitter_mod;

const Value = json.Value;
const ObjectMap = json.ObjectMap;
const HandlerContext = common.HandlerContext;
const DispatchResult = common.DispatchResult;

pub fn handlePickerOpen(ctx: *HandlerContext, params: Value) !DispatchResult {
    const obj = switch (params) {
        .object => |o| o,
        else => return .{ .empty = {} },
    };
    const cwd = json.getString(obj, "cwd") orelse return .{ .empty = {} };

    var result = try json.buildObjectMap(ctx.allocator, .{
        .{ "action", json.jsonString("picker_init") },
        .{ "cwd", json.jsonString(cwd) },
    });
    if (obj.get("recent_files")) |rf| {
        try result.put("recent_files", rf);
    }

    return .{ .data = .{ .object = result } };
}

pub fn handlePickerQuery(ctx: *HandlerContext, params: Value) !DispatchResult {
    const obj = switch (params) {
        .object => |o| o,
        else => return .{ .empty = {} },
    };
    const query = json.getString(obj, "query") orelse "";
    const mode = json.getString(obj, "mode") orelse "file";

    if (std.mem.eql(u8, mode, "workspace_symbol")) {
        const lsp_ctx = switch (try common.getLspContext(ctx, params)) {
            .ready => |c| c,
            .initializing => return .{ .initializing = {} },
            .not_available => return .{ .empty = {} },
        };

        const ws_params = try json.buildObject(ctx.allocator, .{
            .{ "query", json.jsonString(query) },
        });
        const request_id = try lsp_ctx.client.sendRequest("workspace/symbol", ws_params);
        return .{ .pending_lsp = .{ .lsp_request_id = request_id } };
    } else if (std.mem.eql(u8, mode, "grep")) {
        return .{ .data = try json.buildObject(ctx.allocator, .{
            .{ "action", json.jsonString("picker_grep_query") },
            .{ "query", json.jsonString(query) },
        }) };
    } else if (std.mem.eql(u8, mode, "document_symbol")) {
        const ts_state = ctx.ts orelse return .{ .empty = {} };
        const file = json.getString(obj, "file") orelse return .{ .empty = {} };
        const lang_state = ts_state.fromExtension(file) orelse return .{ .empty = {} };

        // Auto-parse if buffer not yet tracked (e.g. picker opened before highlights ran)
        if (ts_state.getTree(file) == null) {
            if (json.getString(obj, "text")) |text| {
                ts_state.parseBuffer(file, text) catch {};
            }
        }

        const tree = ts_state.getTree(file) orelse return .{ .empty = {} };
        const source = ts_state.getSource(file) orelse return .{ .empty = {} };
        const sym_query = lang_state.symbols orelse return .{ .empty = {} };

        const result = try ts_mod.symbols.extractPickerSymbols(
            ctx.allocator,
            sym_query,
            tree,
            source,
        );
        return .{ .data = result };
    } else {
        return .{ .data = try json.buildObject(ctx.allocator, .{
            .{ "action", json.jsonString("picker_file_query") },
            .{ "query", json.jsonString(query) },
        }) };
    }
}

pub fn handlePickerClose(ctx: *HandlerContext, params: Value) !DispatchResult {
    _ = params;
    return .{ .data = try json.buildObject(ctx.allocator, .{
        .{ "action", json.jsonString("picker_close") },
    }) };
}
