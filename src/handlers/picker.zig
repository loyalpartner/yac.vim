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

    var result = ObjectMap.init(ctx.allocator);
    try result.put("action", json.jsonString("picker_init"));
    try result.put("cwd", json.jsonString(cwd));

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

        var ws_params = ObjectMap.init(ctx.allocator);
        try ws_params.put("query", json.jsonString(query));
        const request_id = try lsp_ctx.client.sendRequest("workspace/symbol", .{ .object = ws_params });
        return .{ .pending_lsp = .{ .lsp_request_id = request_id } };
    } else if (std.mem.eql(u8, mode, "grep")) {
        var result = ObjectMap.init(ctx.allocator);
        try result.put("action", json.jsonString("picker_grep_query"));
        try result.put("query", json.jsonString(query));
        return .{ .data = .{ .object = result } };
    } else if (std.mem.eql(u8, mode, "document_symbol")) {
        const ts_state = ctx.ts orelse return .{ .empty = {} };
        const ts_obj = switch (params) {
            .object => |o| o,
            else => return .{ .empty = {} },
        };
        const file = json.getString(ts_obj, "file") orelse return .{ .empty = {} };
        const lang_state = ts_state.fromExtension(file) orelse return .{ .empty = {} };
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
        var result = ObjectMap.init(ctx.allocator);
        try result.put("action", json.jsonString("picker_file_query"));
        try result.put("query", json.jsonString(query));
        return .{ .data = .{ .object = result } };
    }
}

pub fn handlePickerClose(ctx: *HandlerContext, params: Value) !DispatchResult {
    _ = params;
    var result = ObjectMap.init(ctx.allocator);
    try result.put("action", json.jsonString("picker_close"));
    return .{ .data = .{ .object = result } };
}
