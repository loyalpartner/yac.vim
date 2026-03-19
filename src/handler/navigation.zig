const std = @import("std");
const Allocator = std.mem.Allocator;

const app_mod = @import("../app.zig");
const App = app_mod.App;
const lsp_context_mod = @import("../lsp/context.zig");
const lsp_types = @import("../lsp/types.zig");
const handler_types = @import("../lsp/vim_types.zig");
const treesitter_mod = @import("../treesitter/treesitter.zig");

const LspContext = lsp_context_mod.LspContext;
const GotoLocation = handler_types.GotoLocation;
const ReferencesResult = handler_types.ReferencesResult;
const DocumentHighlightResult = handler_types.DocumentHighlightResult;
const HighlightItem = handler_types.HighlightItem;

// ============================================================================
// NavigationHandler — goto, hover, references, call/type hierarchy, highlights
// ============================================================================

pub const NavigationHandler = struct {
    app: *App,

    fn getLspCtx(self: *NavigationHandler, alloc: Allocator, file: []const u8) !?LspContext {
        return LspContext.resolve(&self.app.lsp.registry, alloc, file);
    }

    fn sendTypedPositionRequest(
        self: *NavigationHandler,
        comptime lsp_method: []const u8,
        alloc: Allocator,
        file: []const u8,
        line: u32,
        column: u32,
    ) !lsp_types.ResultType(lsp_method) {
        const lsp_ctx = try self.getLspCtx(alloc, file) orelse return null;
        return lsp_ctx.sendPositionRequest(lsp_method, alloc, line, column);
    }

    pub fn goto_definition(self: *NavigationHandler, alloc: Allocator, p: struct {
        file: []const u8,
        line: u32,
        column: u32,
    }) !?GotoLocation {
        const result = self.sendTypedPositionRequest("textDocument/definition", alloc, p.file, p.line, p.column) catch return null;
        return GotoLocation.fromDefinitionResult(alloc, result);
    }

    pub fn goto_declaration(self: *NavigationHandler, alloc: Allocator, p: struct {
        file: []const u8,
        line: u32,
        column: u32,
    }) !?GotoLocation {
        const result = self.sendTypedPositionRequest("textDocument/declaration", alloc, p.file, p.line, p.column) catch return null;
        return GotoLocation.fromDefinitionResult(alloc, result);
    }

    pub fn goto_type_definition(self: *NavigationHandler, alloc: Allocator, p: struct {
        file: []const u8,
        line: u32,
        column: u32,
    }) !?GotoLocation {
        const result = self.sendTypedPositionRequest("textDocument/typeDefinition", alloc, p.file, p.line, p.column) catch return null;
        return GotoLocation.fromDefinitionResult(alloc, result);
    }

    pub fn goto_implementation(self: *NavigationHandler, alloc: Allocator, p: struct {
        file: []const u8,
        line: u32,
        column: u32,
    }) !?GotoLocation {
        const result = self.sendTypedPositionRequest("textDocument/implementation", alloc, p.file, p.line, p.column) catch return null;
        return GotoLocation.fromDefinitionResult(alloc, result);
    }

    pub fn hover(self: *NavigationHandler, alloc: Allocator, p: struct {
        file: []const u8,
        line: u32,
        column: u32,
    }) !lsp_types.HoverResult {
        return self.sendTypedPositionRequest("textDocument/hover", alloc, p.file, p.line, p.column);
    }

    pub fn references(self: *NavigationHandler, alloc: Allocator, p: struct {
        file: []const u8,
        line: u32,
        column: u32,
    }) !ReferencesResult {
        const empty: ReferencesResult = .{ .locations = &.{} };
        const lsp_ctx = try self.getLspCtx(alloc, p.file) orelse return empty;
        const result = lsp_ctx.client.request("textDocument/references", alloc, .{
            .textDocument = .{ .uri = lsp_ctx.uri },
            .position = .{ .line = @intCast(p.line), .character = @intCast(p.column) },
            .context = .{ .includeDeclaration = true },
        }) catch return empty;
        return ReferencesResult.fromLsp(alloc, result);
    }

    pub fn call_hierarchy(self: *NavigationHandler, alloc: Allocator, p: struct {
        file: []const u8,
        line: u32,
        column: u32,
    }) !lsp_types.CallHierarchyResult {
        return self.sendTypedPositionRequest("textDocument/prepareCallHierarchy", alloc, p.file, p.line, p.column);
    }

    pub fn type_hierarchy(self: *NavigationHandler, alloc: Allocator, p: struct {
        file: []const u8,
        line: u32,
        column: u32,
    }) !lsp_types.TypeHierarchyResult {
        return self.sendTypedPositionRequest("textDocument/prepareTypeHierarchy", alloc, p.file, p.line, p.column);
    }

    pub fn document_highlight(self: *NavigationHandler, alloc: Allocator, p: struct {
        file: []const u8,
        line: u32,
        column: u32,
        text: ?[]const u8 = null,
    }) !?DocumentHighlightResult {
        // Try LSP first
        const typed = self.sendTypedPositionRequest("textDocument/documentHighlight", alloc, p.file, p.line, p.column) catch null;
        const dh_result = DocumentHighlightResult.fromLsp(alloc, typed);
        if (dh_result.highlights.len > 0) {
            return dh_result;
        }

        // Fallback: tree-sitter based
        const tc = app_mod.getTsCtx(&self.app.ts, p.file, p.text) orelse return null;
        const tree = tc.ts.getTree(tc.file) orelse return null;
        const source = tc.ts.getSource(tc.file) orelse return null;
        const ts_result = try treesitter_mod.document_highlight.extractDocumentHighlights(alloc, tree, source, p.line, p.column);
        if (ts_result) |r| {
            var items: std.ArrayList(HighlightItem) = .empty;
            for (r.highlights) |hl| {
                try items.append(alloc, .{
                    .line = hl.line,
                    .col = hl.col,
                    .end_line = hl.end_line,
                    .end_col = hl.end_col,
                    .kind = hl.kind,
                });
            }
            return .{ .highlights = items.items };
        }
        return null;
    }
};
