const std = @import("std");
const json = @import("../json_utils.zig");
const common = @import("common.zig");
const log = @import("../log.zig");
const lsp_info = @import("lsp_info.zig");
const ts_mod = common.treesitter_mod;

const Value = json.Value;
const HandlerContext = common.HandlerContext;

// ============================================================================
// Vim → daemon param types
// ============================================================================

pub const TsBaseParams = struct {
    file: ?[]const u8 = null,
    text: ?[]const u8 = null,
};

pub const TsHighlightsParams = struct {
    file: ?[]const u8 = null,
    text: ?[]const u8 = null,
    start_line: ?i64 = null,
    end_line: ?i64 = null,
};

pub const TsNavigateParams = struct {
    file: ?[]const u8 = null,
    text: ?[]const u8 = null,
    target: ?[]const u8 = null,
    direction: ?[]const u8 = null,
    line: ?i64 = null,
};

pub const TsTextObjectsParams = struct {
    file: ?[]const u8 = null,
    text: ?[]const u8 = null,
    target: ?[]const u8 = null,
    line: ?i64 = null,
    column: ?i64 = null,
};

pub const TsDocHighlightParams = struct {
    file: ?[]const u8 = null,
    text: ?[]const u8 = null,
    line: ?i64 = null,
    column: ?i64 = null,
};

pub const TsHoverHighlightParams = struct {
    markdown: ?[]const u8 = null,
    filetype: ?[]const u8 = null,
};

pub const TsLoadLanguageParams = struct {
    lang_dir: ?[]const u8 = null,
};

const OkResult = common.OkResult;

// ============================================================================
// Tree-sitter context
// ============================================================================

/// Convenience struct that bundles the tree-sitter state needed by handlers.
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

/// Parse a buffer for tree-sitter if the file type is supported (typed params version).
pub fn parseIfSupportedFile(ctx: *HandlerContext, file: []const u8, text: ?[]const u8) void {
    const tc = getTsContext(ctx, file, text) orelse return;
    const t = text orelse return;
    tc.ts.parseBuffer(tc.file, t) catch |e| {
        log.debug("TreeSitter parse failed for {s}: {any}", .{ tc.file, e });
    };
}

/// Remove a buffer from tree-sitter tracking (typed params version).
pub fn removeIfSupportedFile(ctx: *HandlerContext, file: []const u8) void {
    const tc = getTsContext(ctx, file, null) orelse return;
    tc.ts.removeBuffer(tc.file);
}

/// Parse a buffer for tree-sitter if the file type is supported (raw Value — for handleFileOpen).
pub fn parseIfSupported(ctx: *HandlerContext, params: Value) void {
    const p = json.parseTyped(TsBaseParams, ctx.allocator, params) orelse return;
    parseIfSupportedFile(ctx, p.file orelse return, p.text);
}

/// Remove a buffer from tree-sitter tracking (raw Value — for handleFileOpen).
pub fn removeIfSupported(ctx: *HandlerContext, params: Value) void {
    const p = json.parseTyped(TsBaseParams, ctx.allocator, params) orelse return;
    removeIfSupportedFile(ctx, p.file orelse return);
}

pub fn handleTsSymbols(ctx: *HandlerContext, p: TsBaseParams) !?Value {
    const tc = getTsContext(ctx, p.file orelse return null, p.text) orelse return null;
    const tree = tc.ts.getTree(tc.file) orelse return null;
    const source = tc.ts.getSource(tc.file) orelse return null;
    const sym_query = tc.lang_state.symbols orelse return null;

    return try ts_mod.symbols.extractSymbols(
        ctx.allocator,
        sym_query,
        tree,
        source,
        tc.file,
    );
}

pub fn handleTsFolding(ctx: *HandlerContext, p: TsBaseParams) !?Value {
    const tc = getTsContext(ctx, p.file orelse return null, p.text) orelse return null;
    const tree = tc.ts.getTree(tc.file) orelse return null;
    const folds_query = tc.lang_state.folds orelse return null;

    return try ts_mod.folds.extractFolds(
        ctx.allocator,
        folds_query,
        tree,
    );
}

pub fn handleTsNavigate(ctx: *HandlerContext, p: TsNavigateParams) !?Value {
    const tc = getTsContext(ctx, p.file orelse return null, p.text) orelse return null;
    const tree = tc.ts.getTree(tc.file) orelse return null;
    const sym_query = tc.lang_state.symbols orelse return null;

    const line_i64 = p.line orelse return null;
    if (line_i64 < 0) return null;

    return try ts_mod.navigate.navigate(
        ctx.allocator,
        sym_query,
        tree,
        p.target orelse "function",
        p.direction orelse "next",
        @intCast(line_i64),
    );
}

pub fn handleTsTextObjects(ctx: *HandlerContext, p: TsTextObjectsParams) !?Value {
    const tc = getTsContext(ctx, p.file orelse return null, p.text) orelse return null;
    const tree = tc.ts.getTree(tc.file) orelse return null;
    const to_query = tc.lang_state.textobjects orelse return null;

    const target = p.target orelse return null;
    const line_i64 = p.line orelse return null;
    const col_i64 = p.column orelse return null;
    if (line_i64 < 0 or col_i64 < 0) return null;

    return try ts_mod.textobjects.findTextObject(
        ctx.allocator,
        to_query,
        tree,
        target,
        @intCast(line_i64),
        @intCast(col_i64),
    );
}

pub fn handleLoadLanguage(ctx: *HandlerContext, p: TsLoadLanguageParams) !OkResult {
    const ts_state = ctx.ts orelse return .{ .ok = false };
    const lang_dir = p.lang_dir orelse return .{ .ok = false };

    ts_state.loadFromDir(lang_dir);

    return .{ .ok = true };
}

pub fn handleTsHighlights(ctx: *HandlerContext, p: TsHighlightsParams) !?Value {
    const tc = getTsContext(ctx, p.file orelse return null, p.text) orelse return null;
    const tree = tc.ts.getTree(tc.file) orelse return null;
    const source = tc.ts.getSource(tc.file) orelse return null;
    const hl_query = tc.lang_state.highlights orelse return null;
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

    return result;
}

/// Document highlight: try LSP first (semantic), fall back to tree-sitter (textual).
pub fn handleDocumentHighlight(ctx: *HandlerContext, p: TsDocHighlightParams) !?Value {
    // Try LSP — it provides semantic scope awareness.
    // Use the non-deferring LSP variant so we fall through to tree-sitter
    // instead of marking the whole request as deferred.
    const lsp_result = try lsp_info.handleDocumentHighlightLsp(ctx, .{
        .file = p.file,
        .line = p.line,
        .column = p.column,
    });

    // If LSP sent a request (ctx._pending set), return null — response will arrive later
    if (ctx._pending != null) return null;

    // If LSP returned data directly, use it
    if (lsp_result) |data| return data;

    // Fallback: tree-sitter based (textual match within scope)
    const tc = getTsContext(ctx, p.file orelse return null, p.text) orelse return null;
    const tree = tc.ts.getTree(tc.file) orelse return null;
    const source = tc.ts.getSource(tc.file) orelse return null;

    const line_i64 = p.line orelse return null;
    const col_i64 = p.column orelse return null;
    if (line_i64 < 0 or col_i64 < 0) return null;
    const line: u32 = @intCast(line_i64);
    const column: u32 = @intCast(col_i64);

    return try ts_mod.document_highlight.extractDocumentHighlights(
        ctx.allocator,
        tree,
        source,
        line,
        column,
    );
}

pub fn handleTsHoverHighlight(ctx: *HandlerContext, p: TsHoverHighlightParams) !?Value {
    const ts_state = ctx.ts orelse return null;
    const markdown = p.markdown orelse return null;
    const filetype = p.filetype orelse "";

    return try ts_mod.hover_highlight.extractHoverHighlights(
        ctx.allocator,
        ts_state,
        markdown,
        filetype,
    );
}
