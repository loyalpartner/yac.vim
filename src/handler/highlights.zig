const std = @import("std");
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.handler_highlights);

const app_mod = @import("../app.zig");
const App = app_mod.App;
const lsp_context_mod = @import("../lsp/context.zig");
const lsp_context_helpers = @import("../lsp/context.zig");
const lsp_types = @import("../lsp/types.zig");
const handler_types = @import("../lsp/vim_types.zig");
const treesitter_mod = @import("../treesitter/treesitter.zig");

const LspContext = lsp_context_mod.LspContext;
const InlayHintsResult = handler_types.InlayHintsResult;

// ============================================================================
// HighlightsHandler — tree-sitter highlights, LSP inlay hints, semantic tokens
// ============================================================================

pub const HighlightsHandler = struct {
    app: *App,

    fn getLspCtx(self: *HighlightsHandler, alloc: Allocator, file: []const u8) !?LspContext {
        return LspContext.resolve(&self.app.lsp.registry, alloc, file);
    }

    fn serverUnsupported(self: *HighlightsHandler, client_key: []const u8, capability: []const u8) bool {
        return lsp_context_helpers.serverUnsupported(&self.app.lsp.registry, client_key, capability);
    }

    pub fn ts_highlights(self: *HighlightsHandler, alloc: Allocator, p: struct {
        file: []const u8,
        text: ?[]const u8 = null,
        start_line: u32 = 0,
        end_line: u32 = 100,
    }) !?treesitter_mod.highlights.HighlightsResult {
        const tc = app_mod.getTsCtx(&self.app.ts, p.file, p.text) orelse return null;
        const tree = tc.ts.getTree(tc.file) orelse return null;
        const source = tc.ts.getSource(tc.file) orelse return null;
        const hl_query = tc.lang_state.highlights orelse return null;

        var result = try treesitter_mod.highlights.extractHighlights(alloc, hl_query, tree, source, p.start_line, p.end_line);
        if (tc.lang_state.injections) |inj_query| {
            try treesitter_mod.highlights.processInjections(alloc, inj_query, tree, source, p.start_line, p.end_line, tc.ts, &result);
        }
        return result;
    }

    pub fn inlay_hints(self: *HighlightsHandler, alloc: Allocator, p: struct {
        file: []const u8,
        start_line: u32 = 0,
        end_line: u32 = 100,
    }) !InlayHintsResult {
        const empty: InlayHintsResult = .{ .hints = &.{} };
        const lsp_ctx = try self.getLspCtx(alloc, p.file) orelse return empty;
        const result = lsp_ctx.client.request("textDocument/inlayHint", alloc, .{
            .textDocument = .{ .uri = lsp_ctx.uri },
            .range = .{
                .start = .{ .line = @intCast(p.start_line), .character = 0 },
                .end = .{ .line = @intCast(p.end_line), .character = 0 },
            },
        }) catch |e| {
            log.err("LSP inlayHint failed: {any}", .{e});
            return empty;
        };
        return InlayHintsResult.fromLsp(alloc, result);
    }

    pub fn ts_hover_highlight(self: *HighlightsHandler, alloc: Allocator, p: struct {
        markdown: []const u8,
        filetype: []const u8 = "",
    }) !?treesitter_mod.hover_highlight.HoverResult {
        return try treesitter_mod.hover_highlight.extractHoverHighlights(alloc, &self.app.ts, p.markdown, p.filetype);
    }

    pub fn semantic_tokens(self: *HighlightsHandler, alloc: Allocator, p: struct {
        file: []const u8,
    }) !lsp_types.SemanticTokensResult {
        const lsp_ctx = try self.getLspCtx(alloc, p.file) orelse return null;
        if (self.serverUnsupported(lsp_ctx.client_key, "semanticTokensProvider")) return null;
        return lsp_ctx.client.request("textDocument/semanticTokens/full", alloc, .{
            .textDocument = .{ .uri = lsp_ctx.uri },
        }) catch return null;
    }
};
