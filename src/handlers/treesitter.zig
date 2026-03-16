const std = @import("std");
const json = @import("../json_utils.zig");
const common = @import("common.zig");
const log = @import("../log.zig");
const lsp_info = @import("lsp_info.zig");
const ts_mod = common.treesitter_mod;

const Value = json.Value;
const ObjectMap = json.ObjectMap;
const HandlerContext = common.HandlerContext;
const DispatchResult = common.DispatchResult;

// ============================================================================
// Vim → daemon param types
// ============================================================================

const TsBaseParams = struct {
    file: ?[]const u8 = null,
    text: ?[]const u8 = null,
};

const TsHighlightsParams = struct {
    file: ?[]const u8 = null,
    text: ?[]const u8 = null,
    start_line: ?i64 = null,
    end_line: ?i64 = null,
};

const TsNavigateParams = struct {
    file: ?[]const u8 = null,
    text: ?[]const u8 = null,
    target: ?[]const u8 = null,
    direction: ?[]const u8 = null,
    line: ?i64 = null,
};

const TsTextObjectsParams = struct {
    file: ?[]const u8 = null,
    text: ?[]const u8 = null,
    target: ?[]const u8 = null,
    line: ?i64 = null,
    column: ?i64 = null,
};

const TsDocHighlightParams = struct {
    file: ?[]const u8 = null,
    text: ?[]const u8 = null,
    line: ?i64 = null,
    column: ?i64 = null,
};

const TsHoverHighlightParams = struct {
    markdown: ?[]const u8 = null,
    filetype: ?[]const u8 = null,
};

const TsLoadLanguageParams = struct {
    lang_dir: ?[]const u8 = null,
};

// ============================================================================
// Tree-sitter context
// ============================================================================

/// Convenience struct that bundles the tree-sitter state needed by handlers.
/// Extracted from request params by getTsContext(). Like TreeSitter itself,
/// all use must stay on the event-loop thread (see TreeSitter doc comment).
const TsContext = struct {
    ts: *ts_mod.TreeSitter,
    file: []const u8,
    lang_state: *const ts_mod.LangState,
};

fn getTsContext(ctx: *HandlerContext, file: []const u8, text: ?[]const u8) ?TsContext {
    const ts_state = ctx.ts orelse return null;
    const lang_state = ts_state.fromExtension(file) orelse return null;

    // Auto-parse if buffer not yet tracked (e.g. .vim files with no LSP file_open)
    if (ts_state.getTree(file) == null) {
        if (text) |t| {
            ts_state.parseBuffer(file, t) catch |e| {
                log.debug("TreeSitter auto-parse failed for {s}: {any}", .{ file, e });
            };
        }
    }

    return .{ .ts = ts_state, .file = file, .lang_state = lang_state };
}

/// Parse a buffer for tree-sitter if the file type is supported.
/// Called from buffer lifecycle hooks (file_open, did_change).
pub fn parseIfSupported(ctx: *HandlerContext, params: Value) void {
    const p = json.parseTyped(TsBaseParams, ctx.allocator, params) orelse return;
    const tc = getTsContext(ctx, p.file orelse return, p.text) orelse return;
    const text = p.text orelse return;
    tc.ts.parseBuffer(tc.file, text) catch |e| {
        log.debug("TreeSitter parse failed for {s}: {any}", .{ tc.file, e });
    };
}

/// Remove a buffer from tree-sitter tracking if the file type is supported.
/// Called from buffer lifecycle hooks (did_close).
pub fn removeIfSupported(ctx: *HandlerContext, params: Value) void {
    const p = json.parseTyped(TsBaseParams, ctx.allocator, params) orelse return;
    const tc = getTsContext(ctx, p.file orelse return, p.text) orelse return;
    tc.ts.removeBuffer(tc.file);
}

pub fn handleTsSymbols(ctx: *HandlerContext, params: Value) !DispatchResult {
    const p = json.parseTyped(TsBaseParams, ctx.allocator, params) orelse return .{ .empty = {} };
    const tc = getTsContext(ctx, p.file orelse return .{ .empty = {} }, p.text) orelse return .{ .empty = {} };
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
    const p = json.parseTyped(TsBaseParams, ctx.allocator, params) orelse return .{ .empty = {} };
    const tc = getTsContext(ctx, p.file orelse return .{ .empty = {} }, p.text) orelse return .{ .empty = {} };
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
    const p = json.parseTyped(TsNavigateParams, ctx.allocator, params) orelse return .{ .empty = {} };
    const tc = getTsContext(ctx, p.file orelse return .{ .empty = {} }, p.text) orelse return .{ .empty = {} };
    const tree = tc.ts.getTree(tc.file) orelse return .{ .empty = {} };
    const sym_query = tc.lang_state.symbols orelse return .{ .empty = {} };

    const line_i64 = p.line orelse return .{ .empty = {} };
    if (line_i64 < 0) return .{ .empty = {} };

    const result = try ts_mod.navigate.navigate(
        ctx.allocator,
        sym_query,
        tree,
        p.target orelse "function",
        p.direction orelse "next",
        @intCast(line_i64),
    );
    return .{ .data = result };
}

pub fn handleTsTextObjects(ctx: *HandlerContext, params: Value) !DispatchResult {
    const p = json.parseTyped(TsTextObjectsParams, ctx.allocator, params) orelse return .{ .empty = {} };
    const tc = getTsContext(ctx, p.file orelse return .{ .empty = {} }, p.text) orelse return .{ .empty = {} };
    const tree = tc.ts.getTree(tc.file) orelse return .{ .empty = {} };
    const to_query = tc.lang_state.textobjects orelse return .{ .empty = {} };

    const target = p.target orelse return .{ .empty = {} };
    const line_i64 = p.line orelse return .{ .empty = {} };
    const col_i64 = p.column orelse return .{ .empty = {} };
    if (line_i64 < 0 or col_i64 < 0) return .{ .empty = {} };

    const result = try ts_mod.textobjects.findTextObject(
        ctx.allocator,
        to_query,
        tree,
        target,
        @intCast(line_i64),
        @intCast(col_i64),
    );
    return .{ .data = result };
}

pub fn handleLoadLanguage(ctx: *HandlerContext, params: Value) !DispatchResult {
    const ts_state = ctx.ts orelse return .{ .empty = {} };
    const p = json.parseTyped(TsLoadLanguageParams, ctx.allocator, params) orelse return .{ .empty = {} };
    const lang_dir = p.lang_dir orelse return .{ .empty = {} };

    ts_state.loadFromDir(lang_dir);

    return .{ .data = try json.buildObject(ctx.allocator, .{
        .{ "ok", .{ .bool = true } },
    }) };
}

pub fn handleTsHighlights(ctx: *HandlerContext, params: Value) !DispatchResult {
    const p = json.parseTyped(TsHighlightsParams, ctx.allocator, params) orelse return .{ .empty = {} };
    const tc = getTsContext(ctx, p.file orelse return .{ .empty = {} }, p.text) orelse return .{ .empty = {} };
    const tree = tc.ts.getTree(tc.file) orelse return .{ .empty = {} };
    const source = tc.ts.getSource(tc.file) orelse return .{ .empty = {} };
    const hl_query = tc.lang_state.highlights orelse return .{ .empty = {} };
    const start_line: u32 = if (p.start_line) |sl| if (sl >= 0) @intCast(sl) else 0 else 0;
    const end_line: u32 = if (p.end_line) |el| if (el >= 0) @intCast(el) else 100 else 100;

    var result = try ts_mod.highlights.extractHighlights(
        ctx.allocator,
        hl_query,
        tree,
        source,
        start_line,
        end_line,
    );

    // Process injections if the language has an injections query
    if (tc.lang_state.injections) |inj_query| {
        try ts_mod.highlights.processInjections(
            ctx.allocator,
            inj_query,
            tree,
            source,
            start_line,
            end_line,
            tc.ts,
            &result,
        );
    }

    return .{ .data = result };
}

/// Document highlight: try LSP first (semantic), fall back to tree-sitter (textual).
pub fn handleDocumentHighlight(ctx: *HandlerContext, params: Value) !DispatchResult {
    // Try LSP — it provides semantic scope awareness
    const lsp_result = try lsp_info.handleDocumentHighlight(ctx, params);
    switch (lsp_result) {
        .pending_lsp => return lsp_result, // LSP request sent, wait for response
        .initializing => {}, // LSP not ready, fall through to tree-sitter
        .empty => {}, // No LSP available, fall through
        .data, .data_with_subscribe => return lsp_result,
    }

    // Fallback: tree-sitter based (textual match within scope)
    const p = json.parseTyped(TsDocHighlightParams, ctx.allocator, params) orelse return .{ .empty = {} };
    const tc = getTsContext(ctx, p.file orelse return .{ .empty = {} }, p.text) orelse return .{ .empty = {} };
    const tree = tc.ts.getTree(tc.file) orelse return .{ .empty = {} };
    const source = tc.ts.getSource(tc.file) orelse return .{ .empty = {} };

    const line_i64 = p.line orelse return .{ .empty = {} };
    const col_i64 = p.column orelse return .{ .empty = {} };
    if (line_i64 < 0 or col_i64 < 0) return .{ .empty = {} };
    const line: u32 = @intCast(line_i64);
    const column: u32 = @intCast(col_i64);

    const result = try ts_mod.document_highlight.extractDocumentHighlights(
        ctx.allocator,
        tree,
        source,
        line,
        column,
    );
    return .{ .data = result };
}

pub fn handleTsHoverHighlight(ctx: *HandlerContext, params: Value) !DispatchResult {
    const ts_state = ctx.ts orelse return .{ .empty = {} };
    const p = json.parseTyped(TsHoverHighlightParams, ctx.allocator, params) orelse return .{ .empty = {} };
    const markdown = p.markdown orelse return .{ .empty = {} };
    const filetype = p.filetype orelse "";

    const result = try ts_mod.hover_highlight.extractHoverHighlights(
        ctx.allocator,
        ts_state,
        markdown,
        filetype,
    );
    return .{ .data = result };
}
