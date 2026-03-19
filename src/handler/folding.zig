const std = @import("std");
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.handler_folding);

const app_mod = @import("../app.zig");
const App = app_mod.App;
const lsp_context_mod = @import("../lsp/context.zig");
const lsp_types = @import("../lsp/types.zig");
const treesitter_mod = @import("../treesitter/treesitter.zig");

const LspContext = lsp_context_mod.LspContext;

// ============================================================================
// FoldingHandler — tree-sitter folding + LSP folding range
// ============================================================================

pub const FoldingHandler = struct {
    app: *App,
    /// GPA allocator for tree-sitter folds (not arena — folds are long-lived).
    gpa: Allocator,

    fn getLspCtx(self: *FoldingHandler, alloc: Allocator, file: []const u8) !?LspContext {
        return LspContext.resolve(&self.app.lsp.registry, alloc, file);
    }

    pub fn ts_folding(self: *FoldingHandler, _: Allocator, p: struct {
        file: []const u8,
        text: ?[]const u8 = null,
    }) !treesitter_mod.folds.FoldsResult {
        const empty: treesitter_mod.folds.FoldsResult = .{ .ranges = &.{} };
        const tc = app_mod.getTsCtx(&self.app.ts, p.file, p.text) orelse return empty;
        const tree = tc.ts.getTree(tc.file) orelse return empty;
        const folds_query = tc.lang_state.folds orelse return empty;
        return try treesitter_mod.folds.extractFolds(self.gpa, folds_query, tree);
    }

    pub fn folding_range(self: *FoldingHandler, alloc: Allocator, p: struct {
        file: []const u8,
    }) !lsp_types.FoldingRangeResult {
        const lsp_ctx = try self.getLspCtx(alloc, p.file) orelse return null;
        return lsp_ctx.client.request("textDocument/foldingRange", alloc, .{
            .textDocument = .{ .uri = lsp_ctx.uri },
        }) catch return null;
    }
};
