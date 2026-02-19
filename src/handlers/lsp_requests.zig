const std = @import("std");
const json = @import("../json_utils.zig");
const common = @import("common.zig");
const log = @import("../log.zig");

const Value = json.Value;
const ObjectMap = json.ObjectMap;
const HandlerContext = common.HandlerContext;
const DispatchResult = common.DispatchResult;

pub fn handleFileOpen(ctx: *HandlerContext, params: Value) !DispatchResult {
    const lsp_ctx = switch (try common.getLspContextEx(ctx, params, false)) {
        .ready => |c| c,
        .initializing, .not_available => return .{ .empty = {} },
    };

    // Prefer buffer text from Vim (params.text), fallback to reading from disk
    const obj = switch (params) {
        .object => |o| o,
        else => return .{ .empty = {} },
    };
    const content_to_use = json.getString(obj, "text") orelse
        (std.fs.cwd().readFileAlloc(ctx.allocator, lsp_ctx.real_path, 10 * 1024 * 1024) catch |e| {
        log.err("Failed to read file {s}: {any}", .{ lsp_ctx.real_path, e });
        return .{ .empty = {} };
    });

    if (ctx.registry.isInitializing(lsp_ctx.client_key)) {
        // Queue for replay after initialization completes
        ctx.registry.queuePendingOpen(lsp_ctx.client_key, lsp_ctx.uri, lsp_ctx.language, content_to_use) catch |e| {
            log.err("Failed to queue pending open: {any}", .{e});
        };
    } else {
        // Send didOpen now
        var td_item = ObjectMap.init(ctx.allocator);
        try td_item.put("uri", json.jsonString(lsp_ctx.uri));
        try td_item.put("languageId", json.jsonString(lsp_ctx.language));
        try td_item.put("version", json.jsonInteger(1));
        try td_item.put("text", json.jsonString(content_to_use));

        var did_open_params = ObjectMap.init(ctx.allocator);
        try did_open_params.put("textDocument", .{ .object = td_item });

        lsp_ctx.client.sendNotification("textDocument/didOpen", .{ .object = did_open_params }) catch |e| {
            log.err("Failed to send didOpen: {any}", .{e});
        };
    }

    var response = ObjectMap.init(ctx.allocator);
    try response.put("action", json.jsonString("none"));
    return .{ .data = .{ .object = response } };
}

fn handleGoto(ctx: *HandlerContext, params: Value, lsp_method: []const u8) !DispatchResult {
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

    const lsp_params = try common.buildTextDocumentPosition(ctx.allocator, lsp_ctx.uri, line, column);
    const request_id = try lsp_ctx.client.sendRequest(lsp_method, lsp_params);

    return .{ .pending_lsp = .{ .lsp_request_id = request_id } };
}

pub fn handleGotoDefinition(ctx: *HandlerContext, params: Value) !DispatchResult {
    return handleGoto(ctx, params, "textDocument/definition");
}

pub fn handleGotoDeclaration(ctx: *HandlerContext, params: Value) !DispatchResult {
    return handleGoto(ctx, params, "textDocument/declaration");
}

pub fn handleGotoTypeDefinition(ctx: *HandlerContext, params: Value) !DispatchResult {
    return handleGoto(ctx, params, "textDocument/typeDefinition");
}

pub fn handleGotoImplementation(ctx: *HandlerContext, params: Value) !DispatchResult {
    return handleGoto(ctx, params, "textDocument/implementation");
}

pub fn handleHover(ctx: *HandlerContext, params: Value) !DispatchResult {
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

    const lsp_params = try common.buildTextDocumentPosition(ctx.allocator, lsp_ctx.uri, line, column);
    const request_id = try lsp_ctx.client.sendRequest("textDocument/hover", lsp_params);

    return .{ .pending_lsp = .{ .lsp_request_id = request_id } };
}

pub fn handleCompletion(ctx: *HandlerContext, params: Value) !DispatchResult {
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

    const lsp_params = try common.buildTextDocumentPosition(ctx.allocator, lsp_ctx.uri, line, column);
    const request_id = try lsp_ctx.client.sendRequest("textDocument/completion", lsp_params);

    return .{ .pending_lsp = .{ .lsp_request_id = request_id } };
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

    var context_obj = ObjectMap.init(ctx.allocator);
    try context_obj.put("includeDeclaration", json.jsonBool(true));
    try lsp_params_obj.put("context", .{ .object = context_obj });

    const request_id = try lsp_ctx.client.sendRequest("textDocument/references", .{ .object = lsp_params_obj });

    return .{ .pending_lsp = .{ .lsp_request_id = request_id } };
}

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

    const line: u32 = @intCast(json.getInteger(obj, "line") orelse return .{ .empty = {} });
    const column: u32 = @intCast(json.getInteger(obj, "column") orelse return .{ .empty = {} });
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

    const line: u32 = @intCast(json.getInteger(obj, "line") orelse return .{ .empty = {} });
    const column: u32 = @intCast(json.getInteger(obj, "column") orelse return .{ .empty = {} });

    // Build code action params with range
    var td = ObjectMap.init(ctx.allocator);
    try td.put("uri", json.jsonString(lsp_ctx.uri));

    var start = ObjectMap.init(ctx.allocator);
    try start.put("line", json.jsonInteger(@intCast(line)));
    try start.put("character", json.jsonInteger(@intCast(column)));

    var end = ObjectMap.init(ctx.allocator);
    try end.put("line", json.jsonInteger(@intCast(line)));
    try end.put("character", json.jsonInteger(@intCast(column)));

    var range = ObjectMap.init(ctx.allocator);
    try range.put("start", .{ .object = start });
    try range.put("end", .{ .object = end });

    var context_obj = ObjectMap.init(ctx.allocator);
    const diag_array = std.json.Array.init(ctx.allocator);
    try context_obj.put("diagnostics", .{ .array = diag_array });

    var lsp_params = ObjectMap.init(ctx.allocator);
    try lsp_params.put("textDocument", .{ .object = td });
    try lsp_params.put("range", .{ .object = range });
    try lsp_params.put("context", .{ .object = context_obj });

    const request_id = try lsp_ctx.client.sendRequest("textDocument/codeAction", .{ .object = lsp_params });

    return .{ .pending_lsp = .{ .lsp_request_id = request_id } };
}

pub fn handleDocumentSymbols(ctx: *HandlerContext, params: Value) !DispatchResult {
    const lsp_ctx = switch (try common.getLspContext(ctx, params)) {
        .ready => |c| c,
        .initializing => return .{ .initializing = {} },
        .not_available => return .{ .empty = {} },
    };

    const lsp_params = try common.buildTextDocumentIdentifier(ctx.allocator, lsp_ctx.uri);
    const request_id = try lsp_ctx.client.sendRequest("textDocument/documentSymbol", lsp_params);

    return .{ .pending_lsp = .{ .lsp_request_id = request_id } };
}

pub fn handleInlayHints(ctx: *HandlerContext, params: Value) !DispatchResult {
    const lsp_ctx = switch (try common.getLspContext(ctx, params)) {
        .ready => |c| c,
        .initializing => return .{ .initializing = {} },
        .not_available => return .{ .empty = {} },
    };

    const obj = switch (params) {
        .object => |o| o,
        else => return .{ .empty = {} },
    };

    const start_line: u32 = @intCast(json.getInteger(obj, "start_line") orelse 0);
    const end_line: u32 = @intCast(json.getInteger(obj, "end_line") orelse 100);

    var td = ObjectMap.init(ctx.allocator);
    try td.put("uri", json.jsonString(lsp_ctx.uri));

    var start_pos = ObjectMap.init(ctx.allocator);
    try start_pos.put("line", json.jsonInteger(@intCast(start_line)));
    try start_pos.put("character", json.jsonInteger(0));

    var end_pos = ObjectMap.init(ctx.allocator);
    try end_pos.put("line", json.jsonInteger(@intCast(end_line)));
    try end_pos.put("character", json.jsonInteger(0));

    var range = ObjectMap.init(ctx.allocator);
    try range.put("start", .{ .object = start_pos });
    try range.put("end", .{ .object = end_pos });

    var lsp_params = ObjectMap.init(ctx.allocator);
    try lsp_params.put("textDocument", .{ .object = td });
    try lsp_params.put("range", .{ .object = range });

    const request_id = try lsp_ctx.client.sendRequest("textDocument/inlayHint", .{ .object = lsp_params });

    return .{ .pending_lsp = .{ .lsp_request_id = request_id } };
}

pub fn handleFoldingRange(ctx: *HandlerContext, params: Value) !DispatchResult {
    const lsp_ctx = switch (try common.getLspContext(ctx, params)) {
        .ready => |c| c,
        .initializing => return .{ .initializing = {} },
        .not_available => return .{ .empty = {} },
    };

    const lsp_params = try common.buildTextDocumentIdentifier(ctx.allocator, lsp_ctx.uri);
    const request_id = try lsp_ctx.client.sendRequest("textDocument/foldingRange", lsp_params);

    return .{ .pending_lsp = .{ .lsp_request_id = request_id } };
}

pub fn handleCallHierarchy(ctx: *HandlerContext, params: Value) !DispatchResult {
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

    const lsp_params = try common.buildTextDocumentPosition(ctx.allocator, lsp_ctx.uri, line, column);
    const request_id = try lsp_ctx.client.sendRequest("textDocument/prepareCallHierarchy", lsp_params);

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

    var lsp_params = ObjectMap.init(ctx.allocator);
    try lsp_params.put("command", json.jsonString(command));
    if (obj.get("arguments")) |args| {
        try lsp_params.put("arguments", args);
    }

    const request_id = try lsp_ctx.client.sendRequest("workspace/executeCommand", .{ .object = lsp_params });

    return .{ .pending_lsp = .{ .lsp_request_id = request_id } };
}
