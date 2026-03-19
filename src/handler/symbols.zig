const std = @import("std");
const Allocator = std.mem.Allocator;

const app_mod = @import("../app.zig");
const App = app_mod.App;
const lsp_context_mod = @import("../lsp/context.zig");
const lsp_types = @import("../lsp/types.zig");
const handler_types = @import("../lsp/vim_types.zig");
const treesitter_mod = @import("../treesitter/treesitter.zig");

const LspContext = lsp_context_mod.LspContext;
const PickerSymbolResult = handler_types.PickerSymbolResult;

// ============================================================================
// SymbolsHandler — document symbols, workspace symbols, tree-sitter symbols
// ============================================================================

pub const SymbolsHandler = struct {
    app: *App,

    fn getLspCtx(self: *SymbolsHandler, alloc: Allocator, file: []const u8) !?LspContext {
        return LspContext.resolve(&self.app.lsp.registry, alloc, file);
    }

    pub fn ts_symbols(self: *SymbolsHandler, alloc: Allocator, p: struct {
        file: []const u8,
        text: ?[]const u8 = null,
    }) !?treesitter_mod.symbols.SymbolsResult {
        const tc = app_mod.getTsCtx(&self.app.ts, p.file, p.text) orelse return null;
        const tree = tc.ts.getTree(tc.file) orelse return null;
        const source = tc.ts.getSource(tc.file) orelse return null;
        const sym_query = tc.lang_state.symbols orelse return null;
        return try treesitter_mod.symbols.extractSymbols(alloc, sym_query, tree, source, tc.file);
    }

    pub fn document_symbols(self: *SymbolsHandler, alloc: Allocator, p: struct {
        file: []const u8,
    }) !lsp_types.DocumentSymbolResult {
        const lsp_ctx = try self.getLspCtx(alloc, p.file) orelse return null;
        return lsp_ctx.client.request("textDocument/documentSymbol", alloc, .{
            .textDocument = .{ .uri = lsp_ctx.uri },
        }) catch return null;
    }

    pub fn workspace_symbol(self: *SymbolsHandler, alloc: Allocator, p: struct {
        file: []const u8,
        query: []const u8 = "",
    }) !?PickerSymbolResult {
        const lsp_ctx = try self.getLspCtx(alloc, p.file) orelse return null;
        const result = lsp_ctx.client.request("workspace/symbol", alloc, .{
            .query = p.query,
        }) catch return null;
        return PickerSymbolResult.fromWorkspaceSymbol(alloc, result);
    }
};
