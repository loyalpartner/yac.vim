const std = @import("std");
const json = @import("../json_utils.zig");
const common = @import("common.zig");
const log = @import("../log.zig");
const ts_mod = common.treesitter_mod;

const Value = json.Value;
const ObjectMap = json.ObjectMap;
const HandlerContext = common.HandlerContext;
const DispatchResult = common.DispatchResult;

/// Convenience struct that bundles the tree-sitter state needed by handlers.
/// Extracted from request params by getTsContext(). Like TreeSitter itself,
/// all use must stay on the event-loop thread (see TreeSitter doc comment).
const TsContext = struct {
    ts: *ts_mod.TreeSitter,
    file: []const u8,
    lang: ts_mod.Lang,
    lang_state: *const ts_mod.LangState,
    obj: ObjectMap,
};

fn getTsContext(ctx: *HandlerContext, params: Value) ?TsContext {
    const ts_state = ctx.ts orelse return null;
    const obj = switch (params) {
        .object => |o| o,
        else => return null,
    };
    const file = json.getString(obj, "file") orelse return null;
    const lang = ts_mod.Lang.fromExtension(file) orelse return null;
    const lang_state = ts_state.getLangState(lang) orelse return null;
    return .{ .ts = ts_state, .file = file, .lang = lang, .lang_state = lang_state, .obj = obj };
}

/// Parse a buffer for tree-sitter if the file type is supported.
/// Called from buffer lifecycle hooks (file_open, did_change).
pub fn parseIfSupported(ctx: *HandlerContext, params: Value) void {
    const tc = getTsContext(ctx, params) orelse return;
    const text = json.getString(tc.obj, "text") orelse return;
    tc.ts.parseBuffer(tc.file, text) catch |e| {
        log.debug("TreeSitter parse failed for {s}: {any}", .{ tc.file, e });
    };
}

/// Remove a buffer from tree-sitter tracking if the file type is supported.
/// Called from buffer lifecycle hooks (did_close).
pub fn removeIfSupported(ctx: *HandlerContext, params: Value) void {
    const tc = getTsContext(ctx, params) orelse return;
    tc.ts.removeBuffer(tc.file);
}

pub fn handleTsSymbols(ctx: *HandlerContext, params: Value) !DispatchResult {
    const tc = getTsContext(ctx, params) orelse return .{ .empty = {} };
    const tree = tc.ts.getTree(tc.file) orelse return .{ .empty = {} };
    const source = tc.ts.getSource(tc.file) orelse return .{ .empty = {} };
    const sym_query = tc.lang_state.symbols orelse return .{ .empty = {} };

    const result = try ts_mod.symbols.extractSymbols(
        ctx.allocator,
        sym_query,
        tree,
        source,
        tc.file,
    );
    return .{ .data = result };
}

pub fn handleTsFolding(ctx: *HandlerContext, params: Value) !DispatchResult {
    const tc = getTsContext(ctx, params) orelse return .{ .empty = {} };
    const tree = tc.ts.getTree(tc.file) orelse return .{ .empty = {} };
    const folds_query = tc.lang_state.folds orelse return .{ .empty = {} };

    const result = try ts_mod.folds.extractFolds(
        ctx.allocator,
        folds_query,
        tree,
    );
    return .{ .data = result };
}

pub fn handleTsNavigate(ctx: *HandlerContext, params: Value) !DispatchResult {
    const tc = getTsContext(ctx, params) orelse return .{ .empty = {} };
    const tree = tc.ts.getTree(tc.file) orelse return .{ .empty = {} };
    const sym_query = tc.lang_state.symbols orelse return .{ .empty = {} };

    const target = json.getString(tc.obj, "target") orelse "function";
    const direction = json.getString(tc.obj, "direction") orelse "next";
    const line: u32 = @intCast(json.getInteger(tc.obj, "line") orelse return .{ .empty = {} });

    const result = try ts_mod.navigate.navigate(
        ctx.allocator,
        sym_query,
        tree,
        target,
        direction,
        line,
    );
    return .{ .data = result };
}

pub fn handleTsTextObjects(ctx: *HandlerContext, params: Value) !DispatchResult {
    const tc = getTsContext(ctx, params) orelse return .{ .empty = {} };
    const tree = tc.ts.getTree(tc.file) orelse return .{ .empty = {} };
    const to_query = tc.lang_state.textobjects orelse return .{ .empty = {} };

    const target = json.getString(tc.obj, "target") orelse return .{ .empty = {} };
    const line: u32 = @intCast(json.getInteger(tc.obj, "line") orelse return .{ .empty = {} });
    const column: u32 = @intCast(json.getInteger(tc.obj, "column") orelse return .{ .empty = {} });

    const result = try ts_mod.textobjects.findTextObject(
        ctx.allocator,
        to_query,
        tree,
        target,
        line,
        column,
    );
    return .{ .data = result };
}

pub fn handleTsHighlights(ctx: *HandlerContext, params: Value) !DispatchResult {
    const tc = getTsContext(ctx, params) orelse return .{ .empty = {} };
    const tree = tc.ts.getTree(tc.file) orelse return .{ .empty = {} };
    const source = tc.ts.getSource(tc.file) orelse return .{ .empty = {} };
    const hl_query = tc.lang_state.highlights orelse return .{ .empty = {} };
    const start_line: u32 = @intCast(json.getInteger(tc.obj, "start_line") orelse 0);
    const end_line: u32 = @intCast(json.getInteger(tc.obj, "end_line") orelse 100);

    const result = try ts_mod.highlights.extractHighlights(
        ctx.allocator,
        hl_query,
        tree,
        source,
        start_line,
        end_line,
    );
    return .{ .data = result };
}
